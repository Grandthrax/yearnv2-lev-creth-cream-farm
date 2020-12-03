from itertools import count
from brownie import Wei, reverts
from useful_methods import genericStateOfStrat, withdraw, stateOfVault,stateOfStrat,genericStateOfVault, deposit, tend, sleep, harvest
import random
import brownie

def test_screenshot(live_vault,live_strategy, Contract, web3, accounts, chain,cream, currency,samdev, whale):
    vault = live_vault
    strategy = live_strategy
    print(vault.apiVersion())


    currency.approve(vault, 2 ** 256 - 1, {'from': whale})

    vault.deposit(5* 1e18, {'from': whale})
    strategy.harvest({'from': samdev})

    stateOfStrat(strategy, currency, cream)
    stateOfVault(vault, strategy)


def test_add_keeper(live_vault_dai2, Contract, web3, accounts, chain, cdai, comp, dai, live_strategy_dai2,currency, whale,samdev):
    strategist = samdev
    strategy = live_strategy_dai2
    vault = live_vault_dai2

    #stateOfStrat(strategy, dai, comp)
    #genericStateOfVault(vault, dai)

    keeper = Contract.from_explorer("0x13dAda6157Fee283723c0254F43FF1FdADe4EEd6")

    kp3r = Contract.from_explorer("0x1cEB5cB57C4D4E2b2433641b95Dd330A33185A44")

    #strategy.setKeeper(keeper, {'from': strategist})

    #carlos = accounts.at("0x73f2f3A4fF97B6A6d7afc03C449f0e9a0c0d90aB", force=True)

    #keeper.addStrategy(strategy, 1700000, 10, {'from': carlos})

    bot = accounts.at("0xfe56a0dbdad44Dd14E4d560632Cc842c8A13642b", force=True)

    assert keeper.harvestable(strategy) == False

    depositAmount =  Wei('3500 ether')
    deposit(depositAmount, whale, currency, vault)

    assert keeper.harvestable(strategy) == False

    depositAmount =  Wei('1000 ether')
    deposit(depositAmount, whale, currency, vault)
    assert keeper.harvestable(strategy) == True

    keeper.harvest(strategy, {'from': bot})
    balanceBefore = kp3r.balanceOf(bot)
    #print(tx.events) 
    chain.mine(4)
    #assert kp3r.balanceOf(bot) > balanceBefore
    #strategy.harvest({'from': strategist})

    assert keeper.harvestable(strategy) == False

    stateOfStrat(strategy, dai, comp)
    genericStateOfVault(vault, dai)

    #stateOfStrat(strategy, dai, comp)
    #stateOfVault(vault, strategy)
    #depositAmount =  Wei('1000 ether')
    
    #deposit(depositAmount, whale, currency, vault)

    #stateOfStrat(strategy, dai, comp)
    #genericStateOfVault(vault, dai)

    #strategy.harvest({'from': strategist})

    #stateOfStrat(strategy, dai, comp)
    #genericStateOfVault(vault, dai)