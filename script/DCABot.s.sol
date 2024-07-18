// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {DCABot} from "../contracts/DCABot.sol";
import {BotTestHelper} from "../test/BotTestHelper.sol";
import {SigUtils} from "../test/SigUtils.sol";

import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IBotListV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IBotListV3.sol";

import {
    ICreditFacadeV3Multicall,
    EXTERNAL_CALLS_PERMISSION
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";

contract DCABotScript is Script, BotTestHelper {
    // Contracts that we deploy as part of the test
    DCABot public bot = DCABot(address(0));
    ICreditAccountV3 creditAccount = ICreditAccountV3(address(0));

    // Sigutils
    SigUtils internal sigUtils;

    // Tokens
    IERC20 weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // Dependencies
    address uniswapAdapter = 0xea8199179D6A589A0C2Df225095C1DB39A12D257; // UniswapV3Adapter
    address router = 0xE592427A0AEce92De3Edee1F18E0157C05861564; // SwapRouter

    // Actors
    address user;
    uint256 userKey;
    address executor;
    uint256 executorKey;

    // ------ //
    // ERRORS //
    // ------ //

    /// @notice Setup errors.
    error NotEnoughETH();
    error NotEnoughUSDC();

    function setUp() public {
        setupAccounts();
    }

    function setupAccounts() internal {
        userKey = vm.envUint("PRIVATE_KEY");
        user = vm.addr(userKey);
        executorKey = vm.envUint("PRIVATE_KEY_2");
        executor = vm.addr(executorKey);
        console.log("User:");
        console.log(user);
        console.log("Executor:");
        console.log(executor);
    }

    function run() public {
        setUpGearbox("Trade USDC Tier 1");

        vm.startBroadcast(userKey);
        deployBotIfNeeded();
        setupCreditAccountIfNeeded();
        setBotPermissions();
        uint256 orderId = submitOrder();
        console.log("Order created:");
        console.logUint(orderId);
        vm.stopBroadcast();

        sigUtils = new SigUtils(bot.DOMAIN_SEPARATOR());

        vm.startBroadcast(executorKey);
        bot.executeOrder(orderId);
        vm.stopBroadcast();
    }

    function deployBotIfNeeded() internal {
        if (address(bot) != address(0)) {
            return;
        }
        bot = new DCABot(
            address(usdc),
            uniswapAdapter,
            router // alternatively can be called by uniswapAdapter.targetContract
        );
        console.log("DCABot deployed:");
        console.log(address(bot));
    }

    function setBotPermissions() internal {
        if (
            botList.botPermissions(address(bot), address(creditManager), address(creditAccount))
                & EXTERNAL_CALLS_PERMISSION != 0
        ) {
            console.log("Permission present");
            return;
        }
        console.log("No permission, setting");
        creditFacade.setBotPermissions(address(creditAccount), address(bot), uint192(EXTERNAL_CALLS_PERMISSION));
    }

    function setupCreditAccountIfNeeded() internal {
        checkPrerequisites();
        if (address(creditAccount) != address(0)) {
            return;
        }
        creditAccount = openCreditAccount(user, 50_000e6, 100_000e6);
        console.log("Credit account deployed:");
        console.log(address(creditAccount));
    }

    function submitOrder() public returns (uint256 orderId) {
        DCABot.Order memory order = _createOrder(1000e6, 100e6, 10 minutes);

        orderId = bot.submitOrder(order);
    }

    function checkPrerequisites() internal view {
        // ETH balance check
        uint256 balance = user.balance;
        if (balance == 0) {
            revert NotEnoughETH();
        }

        console.log(IERC20Metadata(address(underlying)).name());
        uint256 usdcBanalce = underlying.balanceOf(user);
        console.log(usdcBanalce);
        if (usdcBanalce == 0) {
            revert NotEnoughUSDC();
        }
    }

    function _createOrder(uint256 budget, uint256 amountPerInterval, uint256 interval)
        internal
        view
        returns (DCABot.Order memory order)
    {
        order.borrower = user;
        order.manager = address(creditManager);
        order.account = address(creditAccount);
        order.tokenOut = address(weth);
        order.budget = budget;
        order.amountPerInterval = amountPerInterval;
        order.interval = interval;
        order.deadline = block.timestamp + 15 days;
        return order;
    }

    function _signOrder(DCABot.Order memory order, uint256 nonce, uint256 key)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 digest = sigUtils.getTypeOrderdDataHash(order, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _signCancelOrder(uint256 orderId, uint256 key) internal view returns (bytes memory signature) {
        bytes32 digest = sigUtils.getTypeCancelOrderDataHash(orderId);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        signature = abi.encodePacked(r, s, v);
    }
}
