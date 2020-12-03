import pytest
from brownie import Wei, config


#change these fixtures for generic tests
@pytest.fixture
def currency(interface):
    #this one is creth:
    yield interface.ERC20('0xcBc1065255cBc3aB41a6868c22d1f1C573AB89fd')
    #this one is weth:
    #yield interface.ERC20('0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2')
@pytest.fixture

def vault(gov, rewards, guardian, currency, pm):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault, currency, gov, rewards, "", "")
    yield vault
@pytest.fixture
def rewards(gov):
    yield gov  # TODO: Add rewards contract
@pytest.fixture
def Vault(pm):
    yield pm(config["dependencies"][0]).Vault

@pytest.fixture
def weth(interface):
    yield interface.ERC20('0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2')

@pytest.fixture
def creth(interface):
    yield interface.ERC20('0xcBc1065255cBc3aB41a6868c22d1f1C573AB89fd')


@pytest.fixture
def whale(accounts, web3, weth,dai, creth, gov, chain):
    #big creth wallet
    acc = accounts.at('0x81c4b969e266a4e064b1ff80b9291e2efd289c03', force=True)
    #big binance8 wallet
    #acc = accounts.at('0xf977814e90da44bfa03b6295a0616a897441acec', force=True)

    #lots of weth account
    #wethAcc = accounts.at('0x81C4B969E266A4e064B1ff80b9291e2efD289C03', force=True)


    yield acc

@pytest.fixture()
def strategist(accounts, whale, currency):
    decimals = currency.decimals()
    currency.transfer(accounts[1], 1 * (10 ** decimals), {'from': whale})
    yield accounts[1]


@pytest.fixture
def samdev(accounts):
    yield accounts.at('0xC3D6880fD95E06C816cB030fAc45b3ffe3651Cb0', force=True)
@pytest.fixture
def gov(accounts):
    yield accounts[3]


@pytest.fixture
def guardian(accounts):
    # YFI Whale, probably
    yield accounts[2]

@pytest.fixture
def keeper(accounts):
    # This is our trusty bot!
    yield accounts[4]

@pytest.fixture
def rando(accounts):
    yield accounts[9]


@pytest.fixture
def dai(interface):
    yield interface.ERC20('0x6b175474e89094c44da98b954eedeac495271d0f')

@pytest.fixture
def usdc(interface):
    yield interface.ERC20('0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48')

@pytest.fixture
def live_vault(Vault):
    yield Vault.at('0x20Eb2A369b71C29FC4aFCddBbc1CAB66CCfcB062')

@pytest.fixture
def live_strategy(Strategy):
    yield Strategy.at('0x879B28502223C4F97Fd38dEad123cb7a0214486B')


#@pytest.fixture
#def live_strategy(Strategy):
#    yield YearnDaiCompStratV2.at('0x4C6e9d7E5d69429100Fcc8afB25Ea980065e2773')

#@pytest.fixture
#def live_strategy_dai2(Strategy):
#    yield Strategy.at('0x2D1b8C783646e146312D317E550EF80EC1Cb08C3')

#@pytest.fixture
#def live_vault_dai2(Vault):
#    yield Vault.at('0x1b048bA60b02f36a7b48754f4edf7E1d9729eBc9')

#@pytest.fixture
#def live_vault_weth(Vault):
#    yield Vault.at('0xf20731f26e98516dd83bb645dd757d33826a37b5')

#@pytest.fixture
#def live_strategy_weth(YearnWethCreamStratV2):
#    yield YearnDaiCompStratV2.at('0x97785a81b3505ea9026b2affa709dfd0c9ef24f6')



@pytest.fixture
def earlyadopter(accounts):
    yield accounts.at('0x769B66253237107650C3C6c84747DFa2B071780e', force=True)

@pytest.fixture
def cream(interface):
    yield interface.ERC20('0x2ba592F78dB6436527729929AAf6c908497cB200')

@pytest.fixture
def crcreth(interface):
    yield interface.CErc20I('0xfd609a03B393F1A1cFcAcEdaBf068CAD09a924E2')

#@pytest.fixture(autouse=True)
#def isolation(fn_isolation):
#    pass
@pytest.fixture(scope="module", autouse=True)
def shared_setup(module_isolation):
    pass

@pytest.fixture
def gov(accounts):
    yield accounts[0]




@pytest.fixture
def rando(accounts):
    yield accounts[9]


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@pytest.fixture()
def strategy(strategist,gov, keeper, vault,  Strategy):
    strategy = strategist.deploy(Strategy,vault)
    strategy.setKeeper(keeper)

    vault.addStrategy(
        strategy,
        2 ** 256 - 1,2 ** 256 - 1, 
        1000,  # 0.5% performance fee for Strategist
        {"from": gov},
    )
    yield strategy

@pytest.fixture()
def largerunningstrategy(gov, strategy, currency, vault, whale):

    amount = Wei('19 ether')
    currency.approve(vault, amount, {'from': whale})
    vault.deposit(amount, {'from': whale})    

    strategy.harvest({'from': gov})
    
    #do it again with a smaller amount to replicate being this full for a while
    amount = Wei('1 ether')
    currency.approve(vault, amount, {'from': whale})
    vault.deposit(amount, {'from': whale})   
    strategy.harvest({'from': gov})
    print(strategy.estimatedTotalAssets())
    
    yield strategy

@pytest.fixture()
def enormousrunningstrategy(gov, largerunningstrategy, currency, vault, whale):
    currency.approve(vault, currency.balanceOf(whale), {'from': whale})
    vault.deposit(currency.balanceOf(whale), {'from': whale})   
   
    collat = 0
    
    while collat < largerunningstrategy.collateralTarget() / 1.001e18:

        largerunningstrategy.harvest({'from': gov})
        deposits, borrows = largerunningstrategy.getCurrentPosition()

        collat = borrows / deposits
        print(collat)
        
    
    yield largerunningstrategy

