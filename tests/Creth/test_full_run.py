from itertools import count
from brownie import Wei, reverts
from useful_methods import genericStateOfStrat, withdraw, stateOfStrat,genericStateOfVault, deposit, tend, sleep, harvest
import random
import brownie

def test_full_generic(Strategy, web3, chain, crcreth, Vault,currency, whale, strategist):
    #our humble strategist is going to publish both the vault and the strategy

    

    #deploy vault
    vault = strategist.deploy(
        Vault, currency, strategist, strategist, "TestVault", "Amount"
    )

    deposit_limit = Wei('1_000_000 ether')

    #set limit to the vault
    vault.setDepositLimit(deposit_limit, {"from": strategist})

    #deploy strategy
    strategy = strategist.deploy(Strategy, vault)
    strategy.setMinCompToSell(0.01*1e18, {"from": strategist})

    vault.addStrategy(strategy, deposit_limit, deposit_limit, 100, {"from": strategist})

    genericStateOfStrat(strategy, currency, vault)
    genericStateOfVault(vault, currency)

    
    #our humble strategist deposits some test funds
    depositAmount =  Wei('10 ether')
    currency.transfer(strategist, depositAmount, {"from": whale})
    starting_balance = currency.balanceOf(strategist)
    
    deposit(depositAmount, strategist, currency, vault)
    #print(vault.creditAvailable(strategy))
    genericStateOfStrat(strategy, currency, vault)
    genericStateOfVault(vault, currency)

    assert strategy.estimatedTotalAssets() == 0
    assert strategy.harvestTrigger(1e15) == True
    strategy.harvest({"from": strategist})

    genericStateOfStrat(strategy, currency, vault)
    genericStateOfVault(vault, currency)

    assert strategy.estimatedTotalAssets() >= depositAmount*0.999999 #losing some dust is ok
    assert strategy.harvestTrigger(1) == False

    #whale deposits as well
    whale_deposit  = Wei('20 ether')
    deposit(whale_deposit, whale, currency, vault)
    assert strategy.harvestTrigger(1000000 * 30 * 1e9) == True
    harvest(strategy, strategist, vault)
    genericStateOfStrat(strategy, currency, vault)
    genericStateOfVault(vault, currency)

    for i in range(50):
        waitBlock = random.randint(20,100)
        print(f'\n----wait {waitBlock} blocks----')
        sleep(chain, waitBlock)

        #if harvest condition harvest. if tend tend
        harvest(strategy, strategist, vault)
        tend(strategy, strategist)
        something= True
        action = random.randint(0,9)
        if action == 1:
            withdraw(random.randint(50,100),whale, currency, vault)
        elif action == 2:
            withdraw(random.randint(50,100),whale, currency, vault)
        elif action == 3:
            deposit(Wei(str(f'{random.randint(5,20)} ether')), whale, currency, vault)
        else :
            something = False

        if something:
            genericStateOfStrat(strategy, currency, vault)
            genericStateOfVault(vault, currency)

    #strategist withdraws
    vault.withdraw({"from": strategist})
    genericStateOfStrat(strategy, currency, vault)
    genericStateOfVault(vault, currency)

    profit = currency.balanceOf(strategist) - starting_balance

    print(Wei(profit).to('ether'), ' profit')
    print(vault.strategies(strategy)[6].to('ether'), ' total returns of strat')