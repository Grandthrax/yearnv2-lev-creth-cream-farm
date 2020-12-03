// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.12;

pragma experimental ABIEncoderV2;

import "@yearnvaults/contracts/BaseStrategy.sol";

import "./Interfaces/DyDx/DydxFlashLoanBase.sol";
import "./Interfaces/DyDx/ICallee.sol";

import "@openzeppelinV3/contracts/token/ERC20/IERC20.sol";
import "@openzeppelinV3/contracts/math/SafeMath.sol";
import "@openzeppelinV3/contracts/math/Math.sol";
import "@openzeppelinV3/contracts/utils/Address.sol";
import "@openzeppelinV3/contracts/token/ERC20/SafeERC20.sol";

import "./Interfaces/UniswapInterfaces/IUniswapV2Router02.sol";
import "./Interfaces/UniswapInterfaces/IWETH.sol";

import "./Interfaces/Compound/CErc20I.sol";
import "./Interfaces/Compound/ComptrollerI.sol";

interface bPool{
    function getSwapFee() external view returns (uint);
    
    function gulp(address token) external;
    function getDenormalizedWeight(address token) external view returns (uint);
    function getBalance(address token) external view returns (uint);

    function swapExactAmountIn(
        address tokenIn,
        uint tokenAmountIn,
        address tokenOut,
        uint minAmountOut,
        uint maxPrice
    ) external returns (uint tokenAmountOut, uint spotPriceAfter);

    function calcOutGivenIn(
        uint tokenBalanceIn,
        uint tokenWeightIn,
        uint tokenBalanceOut,
        uint tokenWeightOut,
        uint tokenAmountIn,
        uint swapFee
    ) external pure returns (uint tokenAmountOut);

}

/********************
 *
 *   A leveraged creth cream farm
 *   https://github.com/Grandthrax/yearnv2-lev-creth-cream-farm
 *   v0.2.1
 *
 ********************* */

contract Strategy is BaseStrategy, DydxFlashloanBase, ICallee {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // @notice emitted when trying to do Flash Loan. flashLoan address is 0x00 when no flash loan used
    event Leverage(uint256 amountRequested, uint256 amountGiven, bool deficit, address flashLoan);

    //Flash Loan Providers
    address private constant SOLO = 0x1E0447b19BB6EcFdAe1e4AE1694b0C3659614e4e;

    // Comptroller address for compound.finance
    ComptrollerI public constant comptroller = ComptrollerI(0x3d5BC3c8d13dcB8bF317092d84783c2697AE9258);

    //Only three tokens we use
    address public constant cream = address(0x2ba592F78dB6436527729929AAf6c908497cB200);
    CErc20I public cToken = CErc20I(address(0xfd609a03B393F1A1cFcAcEdaBf068CAD09a924E2));
    address public constant creth = address(0xcBc1065255cBc3aB41a6868c22d1f1C573AB89fd);

    address public constant uniswapRouter = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    address public constant weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    bPool public constant bpool = bPool(address(0xbc338CA728a5D60Df7bc5e3AF5b6dF9DB697d942)); //weth to creth. balancer clone

    //Operating variables
    uint256 public collateralTarget = 0.42 ether; // 45% is creth factor
    uint256 public blocksToLiquidationDangerZone = 46500; // 7 days =  60*60*24*7/13

    uint256 public minWant = 0.01 ether; //Only lend if we have enough want to be worth it
    uint256 public minCompToSell = 0.1 ether; //used both as the threshold to sell but also as a trigger for harvest

    //To deactivate flash loan provider if needed
    bool public DyDxActive = false;

    uint256 public dyDxMarketId;

    constructor(address _vault) public BaseStrategy(_vault)  {
        
        //pre-set approvals
        IERC20(cream).safeApprove(uniswapRouter, uint256(-1));
        IERC20(weth).safeApprove(address(bpool), uint256(-1));
        want.safeApprove(address(cToken), uint256(-1));
        IERC20(weth).safeApprove(SOLO, uint256(-1));

        // You can set these parameters on deployment to whatever you want
        minReportDelay = 86400; // once per 24 hours
        profitFactor = 50; // multiple before triggering harvest

        //borrowing weth
        dyDxMarketId = _getMarketIdFromTokenAddress(SOLO, weth);

        //we do this horrible thing because you can't compare strings in solidity
        require(keccak256(bytes(apiVersion())) == keccak256(bytes(VaultAPI(_vault).apiVersion())), "WRONG VERSION");
    }

    function name() external override pure returns (string memory){
        return "GenericLevCompFarm";
    }

    /*
     * Control Functions
     */
    function setDyDx(bool _dydx) external {
        require(msg.sender == governance() || msg.sender == strategist, "!management"); // dev: not governance or strategist
        DyDxActive = _dydx;
    }

    function setMinCompToSell(uint256 _minCompToSell) external {
        require(msg.sender == governance() || msg.sender == strategist, "!management"); // dev: not governance or strategist
        minCompToSell = _minCompToSell;
    }

    function setMinWant(uint256 _minWant) external {
        require(msg.sender == governance() || msg.sender == strategist, "!management"); // dev: not governance or strategist
        minWant = _minWant;
    }

    function updateMarketId() external {
        require(msg.sender == governance() || msg.sender == strategist, "!management"); // dev: not governance or strategist
        dyDxMarketId = _getMarketIdFromTokenAddress(SOLO, address(want));
    }

    function setCollateralTarget(uint256 _collateralTarget) external {
        require(msg.sender == governance() || msg.sender == strategist, "!management"); // dev: not governance or strategist
        (, uint256 collateralFactorMantissa, ) = comptroller.markets(address(cToken));
        require(collateralFactorMantissa > _collateralTarget, "!dangerous collateral");
        collateralTarget = _collateralTarget;
    }


    
    /*
     * Base External Facing Functions
     */

    /*
     * Expected return this strategy would provide to the Vault the next time `report()` is called
     *
     * The total assets currently in strategy minus what vault believes we have
     * Does not include unrealised profit such as comp.
     */
    function expectedReturn() public view returns (uint256) {
        uint256 estimateAssets = estimatedTotalAssets();

        uint256 debt = vault.strategies(address(this)).totalDebt;
        if (debt > estimateAssets) {
            return 0;
        } else {
            return estimateAssets - debt;
        }
    }

    /*
     * An accurate estimate for the total amount of assets (principle + return)
     * that this strategy is currently managing, denominated in terms of want tokens.
     */
    function estimatedTotalAssets() public override view returns (uint256) {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();

        uint256 _claimableComp = predictCompAccrued();
        uint256 currentComp = IERC20(cream).balanceOf(address(this));

        // Use touch price. it doesnt matter if we are wrong as this is not used for decision making
        uint256 estimatedWant =  priceCheckCreamToCreth(_claimableComp.add(currentComp));
        uint256 conservativeWant = estimatedWant.mul(9).div(10); //10% pessimist

        return want.balanceOf(address(this)).add(deposits).add(conservativeWant).sub(borrows);
    }

    /*
     * Provide a signal to the keeper that `tend()` should be called.
     * (keepers are always reimbursed by yEarn)
     *
     * NOTE: this call and `harvestTrigger` should never return `true` at the same time.
     */
    function tendTrigger(uint256 gasCost) public override view returns (bool) {
        if (harvestTrigger(0)) {
            //harvest takes priority
            return false;
        }

        if (getblocksUntilLiquidation() <= blocksToLiquidationDangerZone) {
            return true;
        }
    }

    /*
     * Provide a signal to the keeper that `harvest()` should be called.
     * gasCost is expected_gas_use * gas_price
     * (keepers are always reimbursed by yEarn)
     *
     * NOTE: this call and `tendTrigger` should never return `true` at the same time.
     */
    function harvestTrigger(uint256 gasCost) public override view returns (bool) {
        uint256 wantGasCost = priceCheckBal(weth, address(want), gasCost);
        
        uint256 compGasCost = priceCheckUni(weth, cream, gasCost);

        StrategyParams memory params = vault.strategies(address(this));

       
        // Should not trigger if strategy is not activated
        if (params.activation == 0) return false;

        // Should trigger if hadn't been called in a while
        if (block.timestamp.sub(params.lastReport) >= minReportDelay) return true;

        // after enough comp has accrued we want the bot to run
        uint256 _claimableComp = predictCompAccrued();

        if (_claimableComp > minCompToSell) {
            // check value of COMP in wei
            if ( _claimableComp.add(IERC20(cream).balanceOf(address(this))) > compGasCost.mul(profitFactor)) {
                return true;
            }
        }

        //check if vault wants lots of money back
        // dont return dust
        uint256 outstanding = vault.debtOutstanding();
        if (outstanding > profitFactor.mul(wantGasCost)) return true;

        // Check for profits and losses
        uint256 total = estimatedTotalAssets();

        uint256 profit = 0;
        if (total > params.totalDebt) profit = total.sub(params.totalDebt); // We've earned a profit!

        uint256 credit =  vault.creditAvailable().add(profit);
        return (profitFactor.mul(wantGasCost) < credit);
    }

    //cream->weth, weth->creth
    function priceCheckCreamToCreth(uint256 _amount) public view returns (uint256){
        uint wethAmount = priceCheckUni(cream, weth, _amount);

        //weth to creth
        uint256 outAmount = priceCheckBal(weth, address(want), wethAmount);

        return outAmount;

        
    }

    //WARNING. manipulatable and simple routing. Only use for safe functions
    function priceCheckBal(address start, address end, uint256 _amount) public view returns (uint256){


        uint256 weightD = bpool.getDenormalizedWeight(start);
        uint256 weightN = bpool.getDenormalizedWeight(end);
        uint256 balanceD = bpool.getBalance(start);
        uint256 balanceN = bpool.getBalance(end);
        uint256 swapFee = bpool.getSwapFee();

        //dai to ntrump
        uint256 outAmount = bpool.calcOutGivenIn(balanceD, weightD, balanceN, weightN, _amount, swapFee);

        return outAmount;

        
    }

    //WARNING. manipulatable and simple routing. Only use for safe functions
    function priceCheckUni(address start, address end, uint256 _amount) public view returns (uint256) {
        if (_amount == 0) {
            return 0;
        }
        address[] memory path;
        if(start == weth){
            path = new address[](2);
            path[0] = weth; 
            path[1] = end;
        }else{
            path = new address[](2);
            path[0] = start; 
            path[1] = weth; 
            path[1] = end;
        }
 
        uint256[] memory amounts = IUniswapV2Router02(uniswapRouter).getAmountsOut(_amount, path);

        return amounts[amounts.length - 1];
    }

    /*****************
     * Public non-base function
     ******************/

    //Calculate how many blocks until we are in liquidation based on current interest rates
    //WARNING does not include compounding so the estimate becomes more innacurate the further ahead we look
    //equation. Compound doesn't include compounding for most blocks
    //((deposits*colateralThreshold - borrows) / (borrows*borrowrate - deposits*colateralThreshold*interestrate));
    function getblocksUntilLiquidation() public view returns (uint256 blocks) {
        (, uint256 collateralFactorMantissa, ) = comptroller.markets(address(cToken));

        (uint256 deposits, uint256 borrows) = getCurrentPosition();

        uint256 borrrowRate = cToken.borrowRatePerBlock();

        uint256 supplyRate = cToken.supplyRatePerBlock();

        uint256 collateralisedDeposit1 = deposits.mul(collateralFactorMantissa);
        uint256 collateralisedDeposit = collateralisedDeposit1.div(1e18);

        uint256 denom1 = borrows.mul(borrrowRate);
        uint256 denom2 = collateralisedDeposit.mul(supplyRate);

        if (denom2 >= denom1) {
            blocks = uint256(-1);
        } else {
            uint256 numer = collateralisedDeposit.sub(borrows);
            uint256 denom = denom1 - denom2;

            blocks = numer.mul(1e18).div(denom);
        }
    }

    // This function makes a prediction on how much comp is accrued
    // It is not 100% accurate as it uses current balances in Compound to predict into the past
    function predictCompAccrued() public view returns (uint256) {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        if (deposits == 0) {
            return 0; // should be impossible to have 0 balance and positive comp accrued
        }

        //comp speed is amount to borrow or deposit (so half the total distribution for want)
        uint256 distributionPerBlock = comptroller.compSpeeds(address(cToken));

        uint256 totalBorrow = cToken.totalBorrows();

        //total supply needs to be echanged to underlying using exchange rate
        uint256 totalSupplyCtoken = cToken.totalSupply();
        uint256 totalSupply = totalSupplyCtoken.mul(cToken.exchangeRateStored()).div(1e18);

        uint256 blockShareSupply = 0;
        if(totalSupply > 0){
            blockShareSupply = deposits.mul(distributionPerBlock).div(totalSupply);
        }
        
        uint256 blockShareBorrow = 0;
        if(totalBorrow > 0){
            blockShareBorrow = borrows.mul(distributionPerBlock).div(totalBorrow);
        }
        
        //how much we expect to earn per block
        uint256 blockShare = blockShareSupply.add(blockShareBorrow);

        //last time we ran harvest
        uint256 lastReport = vault.strategies(address(this)).lastReport;
        uint256 blocksSinceLast= (block.timestamp.sub(lastReport)).div(13); //roughly 13 seconds per block

        return blocksSinceLast.mul(blockShare);
    }

    //Returns the current position
    //WARNING - this returns just the balance at last time someone touched the cToken token. Does not accrue interst in between
    //cToken is very active so not normally an issue.
    function getCurrentPosition() public view returns (uint256 deposits, uint256 borrows) {
        (, uint256 ctokenBalance, uint256 borrowBalance, uint256 exchangeRate) = cToken.getAccountSnapshot(address(this));
        borrows = borrowBalance;

        deposits = ctokenBalance.mul(exchangeRate).div(1e18);
    }

    //statechanging version
    function getLivePosition() public returns (uint256 deposits, uint256 borrows) {
        deposits = cToken.balanceOfUnderlying(address(this));

        //we can use non state changing now because we updated state with balanceOfUnderlying call
        borrows = cToken.borrowBalanceStored(address(this));
    }

    //Same warning as above
    function netBalanceLent() public view returns (uint256) {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        return deposits.sub(borrows);
    }

    /***********
     * internal core logic
     *********** */
    /*
     * A core method.
     * Called at beggining of harvest before providing report to owner
     * 1 - claim accrued comp
     * 2 - if enough to be worth it we sell
     * 3 - because we lose money on our loans we need to offset profit from comp.
     */
    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        ) {

        _profit = 0;
        _loss = 0; //for clarity

        if (cToken.balanceOf(address(this)) == 0) {
            uint256 wantBalance = want.balanceOf(address(this));
            //no position to harvest
            //but we may have some debt to return
            //it is too expensive to free more debt in this method so we do it in adjust position
            _debtPayment = Math.min(wantBalance, _debtOutstanding); 
            return (_profit, _loss, _debtPayment);
        }
        (uint256 deposits, uint256 borrows) = getLivePosition();

        //claim comp accrued
        _claimComp();
        //sell comp
        _disposeOfComp();

        uint256 wantBalance = want.balanceOf(address(this));

        
        uint256 investedBalance = deposits.sub(borrows);
        uint256 balance = investedBalance.add(wantBalance);

        uint256 debt = vault.strategies(address(this)).totalDebt;

        //Balance - Total Debt is profit
        if (balance > debt) {
            _profit = balance - debt;

            if (wantBalance < _profit) {
                //all reserve is profit                
                _profit = wantBalance;
            } else if (wantBalance > _profit.add(_debtOutstanding)){
                _debtPayment = _debtOutstanding;
            }else{
                _debtPayment = wantBalance - _profit;
            }
        } else {
            //we will lose money until we claim comp then we will make money
            //this has an unintended side effect of slowly lowering our total debt allowed
            _loss = debt - balance;
            _debtPayment = Math.min(wantBalance, _debtOutstanding);
        }
    }

    /*
     * Second core function. Happens after report call.
     *
     * Similar to deposit function from V1 strategy
     */

    function adjustPosition(uint256 _debtOutstanding) internal override {
        //emergency exit is dealt with in prepareReturn
        if (emergencyExit) {
            return;
        }

        //we are spending all our cash unless we have debt outstanding
        uint256 _wantBal = want.balanceOf(address(this));
        if(_wantBal < _debtOutstanding){
            //this is graceful withdrawal. dont use backup
            //we use more than 1 because withdrawunderlying causes problems with 1 token due to different decimals
            if(cToken.balanceOf(address(this)) > 1){ 
                _withdrawSome(_debtOutstanding - _wantBal);
            }

            return;
        }
        

        (uint256 position, bool deficit) = _calculateDesiredPosition(_wantBal - _debtOutstanding, true);
       
        
        //if we are below minimun want change it is not worth doing
        //need to be careful in case this pushes to liquidation
        if (position > minWant) {
            
            //if dydx is not active we just try our best with basic leverage
            if (!DyDxActive) {
                uint i = 5;
                while(position > 0){
                    position = position.sub(_noFlashLoan(position, deficit));
                    i++;
                }
            } else {
                //if there is huge position to improve we want to do normal leverage. it is quicker
                if (position > want.balanceOf(SOLO)) {
                    position = position.sub(_noFlashLoan(position, deficit));
                }

                //flash loan to position
                if(position > 0){
                    doDyDxFlashLoan(deficit, position);
                }

            }
        }
    }

    /*************
     * Very important function
     * Input: amount we want to withdraw and whether we are happy to pay extra for Aave.
     *       cannot be more than we have
     * Returns amount we were able to withdraw. notall if user has some balance left
     *
     * Deleverage position -> redeem our cTokens
     ******************** */
    function _withdrawSome(uint256 _amount) internal returns (bool notAll) {
        (uint256 position, bool deficit) = _calculateDesiredPosition(_amount, false);

        //If there is no deficit we dont need to adjust position
        if (deficit) {
            //we do a flash loan to give us a big gap. from here on out it is cheaper to use normal deleverage. Use Aave for extremely large loans
            if (DyDxActive) {
                position = position.sub(doDyDxFlashLoan(deficit, position));
            }

            uint8 i = 0;
            //position will equal 0 unless we haven't been able to deleverage enough with flash loan
            //if we are not in deficit we dont need to do flash loan
            while (position > 0) {
                position = position.sub(_noFlashLoan(position, true));
                i++;

                //A limit set so we don't run out of gas
                if (i >= 5) {
                    notAll = true;
                    break;
                }
            }
        }

        //now withdraw
        //if we want too much we just take max

        //This part makes sure our withdrawal does not force us into liquidation
        (uint256 depositBalance, uint256 borrowBalance) = getCurrentPosition();

        uint256 AmountNeeded = 0;
        if(collateralTarget > 0){
            AmountNeeded = borrowBalance.mul(1e18).div(collateralTarget);
        }
        uint256 redeemable = depositBalance.sub(AmountNeeded);

        if (redeemable < _amount) {
            cToken.redeemUnderlying(redeemable);
        } else {
            cToken.redeemUnderlying(_amount);
        }

        //let's sell some comp if we have more than needed
        //flash loan would have sent us comp if we had some accrued so we don't need to call claim comp
        _disposeOfComp();
    }

    /***********
     *  This is the main logic for calculating how to change our lends and borrows
     *  Input: balance. The net amount we are going to deposit/withdraw.
     *  Input: dep. Is it a deposit or withdrawal
     *  Output: position. The amount we want to change our current borrow position.
     *  Output: deficit. True if we are reducing position size
     *
     *  For instance deficit =false, position 100 means increase borrowed balance by 100
     ****** */
    function _calculateDesiredPosition(uint256 balance, bool dep) internal returns (uint256 position, bool deficit) {
        //we want to use statechanging for safety
        (uint256 deposits, uint256 borrows) = getLivePosition();

        //When we unwind we end up with the difference between borrow and supply
        uint256 unwoundDeposit = deposits.sub(borrows);

        //we want to see how close to collateral target we are.
        //So we take our unwound deposits and add or remove the balance we are are adding/removing.
        //This gives us our desired future undwoundDeposit (desired supply)

        uint256 desiredSupply = 0;
        if (dep) {
            desiredSupply = unwoundDeposit.add(balance);
        } else { 
            if(balance > unwoundDeposit) balance = unwoundDeposit;
            desiredSupply = unwoundDeposit.sub(balance);
        }

        //(ds *c)/(1-c)
        uint256 num = desiredSupply.mul(collateralTarget);
        uint256 den = uint256(1e18).sub(collateralTarget);

        uint256 desiredBorrow = num.div(den);
        if (desiredBorrow > 1e16) {
            //stop us going right up to the wire
            desiredBorrow = desiredBorrow - 1e16;
        }

        //now we see if we want to add or remove balance
        // if the desired borrow is less than our current borrow we are in deficit. so we want to reduce position
        if (desiredBorrow < borrows) {
            deficit = true;
            position = borrows - desiredBorrow; //safemath check done in if statement
        } else {
            //otherwise we want to increase position
            deficit = false;
            position = desiredBorrow - borrows;
        }
    }

    /*
     * Liquidate as many assets as possible to `want`, irregardless of slippage,
     * up to `_amount`. Any excess should be re-invested here as well.
     */
    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _amountFreed) {
        uint256 _balance = want.balanceOf(address(this));
        uint256 lent = netBalanceLent();

        if (lent.add(_balance) < _amountNeeded) {
            //if we cant afford to withdraw we take all we can
            //withdraw all we can
            _withdrawSome(lent);
            return want.balanceOf(address(this));
        } else {
            if (_balance < _amountNeeded) {
                _withdrawSome(_amountNeeded.sub(_balance));
                _amountFreed = want.balanceOf(address(this));
            }else{
                _amountFreed = _balance - _amountNeeded;
            }
        }
    }

    function claimComp() public {
        require(msg.sender == governance() || msg.sender == strategist, "!management");

        _claimComp();
    }

    function _claimComp() internal {
        CTokenI[] memory tokens = new CTokenI[](1);
        tokens[0] = cToken;

        comptroller.claimComp(address(this), tokens);
    }

    //sell comp function
    function _disposeOfComp() internal {
        uint256 _comp = IERC20(cream).balanceOf(address(this));

        //part one
        if (_comp > minCompToSell) {
            address[] memory path = new address[](2);
            path[0] = cream;
            path[1] = weth;

            IUniswapV2Router02(uniswapRouter).swapExactTokensForTokens(_comp, uint256(0), path, address(this), now);

            uint256 wethB = IWETH(weth).balanceOf(address(this));


            if(wethB > 0){
                //part two
                bpool.swapExactAmountIn(
                weth,wethB,address(want), 0,uint256(-1));
            }

        }       
    }

    /*
     * Make as much capital as possible "free" for the Vault to take. Some slippage
     * is allowed.
     */
    function exitPosition(uint256 _debtOutstanding) internal override returns (uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment){
        return prepareReturn(_debtOutstanding);
    }

    //lets leave
    function prepareMigration(address _newStrategy) internal override {
        (uint256 deposits, uint256 borrows) = getLivePosition();
        _withdrawSome(deposits.sub(borrows));

        (, , uint256 borrowBalance, ) = cToken.getAccountSnapshot(address(this));

        require(borrowBalance == 0, "DELEVERAGE_FIRST");

        want.safeTransfer(_newStrategy, want.balanceOf(address(this)));

        cToken.transfer(_newStrategy, cToken.balanceOf(address(this)));

        IERC20 _comp = IERC20(cream);
        _comp.safeTransfer(_newStrategy, _comp.balanceOf(address(this)));
    }

    //Three functions covering normal leverage and deleverage situations
    // max is the max amount we want to increase our borrowed balance
    // returns the amount we actually did
    function _noFlashLoan(uint256 max, bool deficit) internal returns (uint256 amount) {
        //we can use non-state changing because this function is always called after _calculateDesiredPosition
        (uint256 lent, uint256 borrowed) = getCurrentPosition();

        if (borrowed == 0 && deficit) {
            return 0;
        }

        (, uint256 collateralFactorMantissa, ) = comptroller.markets(address(cToken));

        if (deficit) {
            amount = _normalDeleverage(max, lent, borrowed, collateralFactorMantissa);
        } else {
            amount = _normalLeverage(max, lent, borrowed, collateralFactorMantissa);
        }

        emit Leverage(max, amount, deficit, address(0));
    }

    //maxDeleverage is how much we want to reduce by
    function _normalDeleverage(
        uint256 maxDeleverage,
        uint256 lent,
        uint256 borrowed,
        uint256 collatRatio
    ) internal returns (uint256 deleveragedAmount) {
        uint256 theoreticalLent = borrowed.mul(1e18).div(collatRatio);

        deleveragedAmount = lent.sub(theoreticalLent);

        if (deleveragedAmount >= borrowed) {
            deleveragedAmount = borrowed;
        }
        if (deleveragedAmount >= maxDeleverage) {
            deleveragedAmount = maxDeleverage;
        }

        cToken.redeemUnderlying(deleveragedAmount);

        //our borrow has been increased by no more than maxDeleverage
        cToken.repayBorrow(deleveragedAmount);
    }

    //maxDeleverage is how much we want to increase by
    function _normalLeverage(
        uint256 maxLeverage,
        uint256 lent,
        uint256 borrowed,
        uint256 collatRatio
    ) internal returns (uint256 leveragedAmount) {
        uint256 theoreticalBorrow = lent.mul(collatRatio).div(1e18);

        leveragedAmount = theoreticalBorrow.sub(borrowed);

        if (leveragedAmount >= maxLeverage) {
            leveragedAmount = maxLeverage;
        }

        cToken.borrow(leveragedAmount);
        cToken.mint(want.balanceOf(address(this)));
    }

    //called by flash loan
    function _loanLogic(
        bool deficit,
        uint256 amount,
        uint256 repayAmount
    ) internal {
        uint256 bal = want.balanceOf(address(this));
        require(bal >= amount, "FLASH_FAILED"); // to stop malicious calls

        //if in deficit we repay amount and then withdraw
        if (deficit) {
            cToken.repayBorrow(amount);

            //if we are withdrawing we take more to cover fee
            cToken.redeemUnderlying(repayAmount);
        } else {
            require(cToken.mint(bal) == 0, "mint error");

            //borrow more to cover fee
            // fee is so low for dydx that it does not effect our liquidation risk.
            //DONT USE FOR AAVE
            cToken.borrow(repayAmount);
        }
    }

    function protectedTokens() internal override view returns (address[] memory) {
        address[] memory protected = new address[](4);
        protected[0] = address(want);
        protected[1] = cream;
        protected[2] = address(cToken);
        protected[3] = weth;
        return protected;
    }

    /******************
     * Flash loan stuff
     ****************/

    // Flash loan DXDY
    // amount desired is how much we are willing for position to change
    function doDyDxFlashLoan(bool deficit, uint256 amountDesired) internal returns (uint256) {
        uint256 amount = amountDesired;
        ISoloMargin solo = ISoloMargin(SOLO);
        

        // Not enough want in DyDx. So we take all we can
        uint256 amountInSolo = want.balanceOf(SOLO);
        

        if (amountInSolo < amount) {
            amount = amountInSolo;
        }

        uint256 repayAmount = amount.add(2); // we need to overcollateralise on way back

        bytes memory data = abi.encode(deficit, amount, repayAmount);

        // 1. Withdraw $
        // 2. Call callFunction(...)
        // 3. Deposit back $
        Actions.ActionArgs[] memory operations = new Actions.ActionArgs[](3);

        operations[0] = _getWithdrawAction(dyDxMarketId, amount);
        operations[1] = _getCallAction(
            // Encode custom data for callFunction
            data
        );
        operations[2] = _getDepositAction(dyDxMarketId, repayAmount);

        Account.Info[] memory accountInfos = new Account.Info[](1);
        accountInfos[0] = _getAccountInfo();

        solo.operate(accountInfos, operations);

        emit Leverage(amountDesired, amount, deficit, SOLO);

        return amount;
    }

    //returns our current collateralisation ratio. Should be compared with collateralTarget
    function storedCollateralisation() public view returns (uint256 collat) {
        (uint256 lend, uint256 borrow) = getCurrentPosition();
        if (lend == 0) {
            return 0;
        }
        collat = uint256(1e18).mul(borrow).div(lend);
    }

    //DyDx calls this function after doing flash loan
    function callFunction(
        address sender,
        Account.Info memory account,
        bytes memory data
    ) public override {
        (bool deficit, uint256 amount, uint256 repayAmount) = abi.decode(data, (bool, uint256, uint256));
        require(msg.sender == SOLO, "NOT_SOLO");

        _loanLogic(deficit, amount, repayAmount);
    }

    
}
