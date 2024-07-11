// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {console} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {
    ICreditFacadeV3Multicall,
    EXTERNAL_CALLS_PERMISSION
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";

import {DCABot} from "../contracts/DCABot.sol";

import {BotTestHelper} from "./BotTestHelper.sol";

contract DCABotTest is BotTestHelper {
    // tested bot
    DCABot public bot;
    ICreditAccountV3 creditAccount;

    // tokens
    IERC20 weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    
    // dependencies
    address uniswapAdapter = 0xea8199179D6A589A0C2Df225095C1DB39A12D257; // UniswapV3Adapter

    // actors
    address user;
    address executor;

    function setUp() public {
        user = makeAddr("USER");
        executor = makeAddr("EXECUTOR");

        setUpGearbox("Trade USDC Tier 1");

        creditAccount = openCreditAccount(user, 50_000e6, 100_000e6);

        bot = new DCABot(
            address(usdc),
            uniswapAdapter
        );
        vm.prank(user);
        creditFacade.setBotPermissions(
            address(creditAccount), address(bot), uint192(EXTERNAL_CALLS_PERMISSION)
        );

        // let's make weth non-quoted for this test because bot doesn't work with quotas
        uint256 quotedTokensMask = creditManager.quotedTokensMask();
        uint256 wethMask = creditManager.getTokenMaskOrRevert(address(weth));

        vm.prank(creditManager.creditConfigurator());
        creditManager.setQuotedMask(quotedTokensMask & ~wethMask);
    }

    function test_DCA_01_setUp_is_correct() public view {
        assertEq(address(underlying), address(usdc), "Incorrect underlying");
        assertEq(creditManager.getBorrowerOrRevert(address(creditAccount)), user, "Incorrect account owner");
        assertEq(usdc.balanceOf(address(creditAccount)), 150_000e6, "Incorrect account balance of underlying");
        assertEq(creditFacade.botList(), address(botList), "Incorrect bot list");
        assertEq(
            botList.botPermissions(address(bot), address(creditManager), address(creditAccount)),
            EXTERNAL_CALLS_PERMISSION,
            "Incorrect bot permissions"
        );
    }

    // U:[DCA-02]
    function test_DCA_02_submitOrder_reverts_if_caller_is_not_borrower() public {
        DCABot.Order memory order;

        vm.expectRevert(DCABot.CallerNotBorrower.selector);
        vm.prank(user);
        bot.submitOrder(order);

        address caller = makeAddr("CALLER");
        order.borrower = caller;
        order.manager = address(creditManager);
        order.account = address(creditAccount);

        vm.expectRevert(DCABot.CallerNotBorrower.selector);
        vm.prank(caller);
        bot.submitOrder(order);
    }

    function test_DCA_03_submitOrder_works_as_expected_when_called_properly() public {
        DCABot.Order memory order = DCABot.Order({
            borrower: user,
            manager: address(creditManager),
            account: address(creditAccount),
            tokenOut: address(weth),
            budget: 1000,
            totalSpend:  0,
            interval: 1 days,
            amountPerInterval: 100,
            lastPrice: 0,
            lastPurchaseTime: 0,
            deadline: block.timestamp + 7 days
        });
        order.borrower = user;

        vm.expectEmit(true, true, true, true);
        emit DCABot.CreateOrder(user, 0);

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);
        assertEq(orderId, 0, "Incorrect orderId");

        _assertOrderIsEqual(orderId, order);
    }

    // U:[DCA-04]
    function test_DCA_04_cancelOrder_reverts_if_caller_is_not_borrower() public {
        DCABot.Order memory order = _dummyOrder();

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);

        address caller = makeAddr("CALLER");
        vm.expectRevert(DCABot.CallerNotBorrower.selector);
        vm.prank(caller);
        bot.cancelOrder(orderId);
    }

    function test_DCA_05_cancelOrder_works_as_expected_when_called_properly() public {
        DCABot.Order memory order = _dummyOrder();

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);

        vm.expectEmit(true, true, true, true);
        emit DCABot.CancelOrder(user, orderId);

        vm.prank(user);
        bot.cancelOrder(orderId);

        _assertOrderIsEmpty(orderId);
    }

    // U:[DCA-06]
    function test_DCA_06_executeOrder_reverts_if_order_is_cancelled() public {
        DCABot.Order memory order = _dummyOrder();

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);

        vm.prank(user);
        bot.cancelOrder(orderId);

        vm.expectRevert(DCABot.OrderIsCancelled.selector);
        vm.prank(executor);
        bot.executeOrder(orderId);
    }

    // U:[DCA-07]
    function test_DCA_07_executeOrder_reverts_if_account_borrower_changes() public {
        DCABot.Order memory order = _dummyOrder();

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);

        vm.mockCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.getBorrowerOrRevert, (address(creditAccount))),
            abi.encode(makeAddr("OTHER_USER"))
        );

        vm.expectRevert(DCABot.CreditAccountBorrowerChanged.selector);
        vm.prank(executor);
        bot.executeOrder(orderId);
    }

    // U:[DCA-08]
    function test_DCA_08_executeOrder_reverts_if_order_is_invalid() public {
        DCABot.Order memory order = _dummyOrder();
        order.tokenOut = address(usdc);

        // Compared to limit order bot - we've moved reverts to order submission
        vm.prank(user);
        vm.expectRevert(DCABot.InvalidOrder.selector);
        bot.submitOrder(order);

        // returning order to correct state
        order.tokenOut = address(weth);
        vm.prank(user);
        bot.submitOrder(order);

        // Creating order with incorrect total spend
        order.totalSpend = 1000;
        vm.prank(user);
        vm.expectRevert(DCABot.InvalidOrder.selector);
        bot.submitOrder(order);
    }

    // U:[DCA-09]
    function test_DCA_09_executeOrder_reverts_if_order_is_expired() public {
        DCABot.Order memory order = _dummyOrder();
        order.deadline = block.timestamp - 1;

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);

        vm.expectRevert(DCABot.Expired.selector);
        vm.prank(executor);
        bot.executeOrder(orderId);
    }

    // function test_DCA_10_executeOrder_reverts_if_price_swing_too_large() public {
    //     DCABot.Order memory order = _dummyOrder();
    //     order.deadline = block.timestamp + 1 days;

    //     vm.prank(user);
    //     uint256 orderId = bot.submitOrder(order);

    //     vm.expectRevert(DCABot.NotTriggered.selector);
    //     vm.prank(executor);
    //     bot.executeOrder(orderId);
    // }

    // function test_DCA_11_executeOrder_reverts_if_account_has_no_quote_token() public {
    //     DCABot.Order memory order;
    //     order.borrower = user;
    //     order.manager = address(creditManager);
    //     order.account = address(creditAccount);
    //     order.tokenIn = address(weth);
    //     order.tokenOut = address(usdc);
    //     order.amountIn = 123;
    //     order.deadline = block.timestamp;

    //     vm.prank(user);
    //     uint256 orderId = bot.submitOrder(order);

    //     vm.expectRevert(DCABot.NothingToSell.selector);
    //     vm.prank(executor);
    //     bot.executeOrder(orderId);
    // }

    function test_DCA_12_executeOrder_works_as_expected_when_called_properly() public {
        DCABot.Order memory order;
        order.borrower = user;
        order.manager = address(creditManager);
        order.account = address(creditAccount);
        order.tokenOut = address(weth);
        order.budget = 1000e6;
        order.amountPerInterval = 100e6;
        order.interval = 1 days;
        order.deadline = block.timestamp;

        uint256 priceOfPurchaseFromOracle = priceOracle.convert(order.amountPerInterval, address(usdc), address(weth));

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);

        uint256 usdcAmount = 100000e6;
        deal({token: address(usdc), to: executor, give: usdcAmount});
        vm.prank(executor);
        usdc.approve(address(bot), usdcAmount);

        vm.expectEmit(true, true, true, false);
        emit DCABot.PurchaseCompleted(executor, orderId, 0);

        address creditAddress = address(creditAccount);

        uint256 executorUSDCBefore = usdc.balanceOf(executor);
        uint256 executorWETHBefore = weth.balanceOf(executor);
        uint256 creditUSDCBefore = usdc.balanceOf(creditAddress);
        uint256 creditWETHBefore = weth.balanceOf(creditAddress);

        vm.prank(executor);
        bot.executeOrder(orderId);

        assertEq(usdc.balanceOf(executor), executorUSDCBefore, "Executor lost USDC");
        assertEq(weth.balanceOf(executor), executorWETHBefore, "Executor lost WETH");
        assertEq(
            usdc.balanceOf(creditAddress), 
            creditUSDCBefore - order.amountPerInterval, 
            "Incorrect USDC balance after trade"
        );
        assertApproxEqAbs(
            weth.balanceOf(creditAddress), 
            creditWETHBefore + priceOfPurchaseFromOracle, 
            (priceOfPurchaseFromOracle * (bot.slippageDenominator() - bot.slippageCoefficient()) / bot.slippageDenominator()),
            "Incorrect WETH balance after trade"
        );

        // _assertOrderIsEmpty(orderId);

        // assertEq(usdc.balanceOf(executor), 150_000e6 - 1, "Incorrect executor USDC balance");
        // assertEq(usdc.balanceOf(address(creditAccount)), 1, "Incorrect account USDC balance");
        // assertEq(weth.balanceOf(executor), 0, "Incorrect executor WETH balance");
        // assertEq(weth.balanceOf(address(creditAccount)), wethAmount, "Incorrect account WETH balance");
    }

    function _assertOrderIsEqual(uint256 orderId, DCABot.Order memory order) internal view {
        (
            address borrower,
            address manager,
            address account,
            address tokenOut,
            uint256 budget,
            uint256 interval,
            uint256 amountPerInterval,
            uint256 totalSpend,
            uint256 lastPrice,
            uint256 lastPurchaseTime,
            uint256 deadline
        ) = bot.orders(orderId);
        assertEq(borrower, order.borrower, "Incorrect borrower");
        assertEq(manager, order.manager, "Incorrect manager");
        assertEq(account, order.account, "Incorrect account");
        assertEq(tokenOut, order.tokenOut, "Incorrect tokenOut");
        assertEq(budget, order.budget, "Incorrect budget");
        assertEq(totalSpend, order.totalSpend, "Incorrect totalSpend");
        assertEq(interval, order.interval, "Incorrect interval");
        assertEq(amountPerInterval, order.amountPerInterval, "Incorrect amountPerInterval");
        assertEq(lastPrice, order.lastPrice, "Incorrect lastPrice");
        assertEq(lastPurchaseTime, order.lastPurchaseTime, "Incorrect lastPurchaseTime");
        assertEq(deadline, order.deadline, "Incorrect deadline");
    }

    function _assertOrderIsEmpty(uint256 orderId) internal view {
        (
            address borrower,
            address manager,
            address account,
            address tokenOut,
            uint256 budget,
            uint256 interval,
            uint256 amountPerInterval,
            uint256 totalSpend,
            uint256 lastPrice,
            uint256 lastPurchaseTime,
            uint256 deadline
        ) = bot.orders(orderId);
        assertEq(borrower, address(0), "Incorrect borrower");
        assertEq(manager, address(0), "Incorrect manager");
        assertEq(account, address(0), "Incorrect account");
        assertEq(tokenOut, address(0), "Incorrect tokenOut");
        assertEq(budget, 0, "Incorrect budget");
        assertEq(totalSpend, 0, "Incorrect totalSpend");
        assertEq(interval, 0, "Incorrect interval");
        assertEq(amountPerInterval, 0, "Incorrect amountPerInterval");
        assertEq(lastPrice, 0, "Incorrect lastPrice");
        assertEq(lastPurchaseTime, 0, "Incorrect lastPurchaseTime");
        assertEq(deadline, 0, "Incorrect deadline");
    }

    function _dummyOrder() internal view returns (DCABot.Order memory order) {
        order.borrower = user;
        order.manager = address(creditManager);
        order.account = address(creditAccount);
        order.tokenOut = address(weth);
        order.amountPerInterval = 1;
        order.interval = 1;
    }
}
