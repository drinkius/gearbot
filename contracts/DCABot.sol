// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";

import {IUniswapV3Adapter, ISwapRouter} from "./interfaces/IUniswapV3Adapter.sol";

/// @title Dollar Cost Average (DCA) bot.
/// @notice Allows Gearbox users to submit DCA orders. Arbitrary accounts can execute these orders.
contract DCABot is EIP712 {
    // ----- //
    // TYPES //
    // ----- //

    /// @notice DCA order data.
    struct Order {
        address borrower;
        address manager;
        address account;
        address tokenOut;
        uint256 budget;
        uint256 interval;
        uint256 amountPerInterval;
        uint256 totalSpend;
        uint256 lastPrice;
        uint256 lastPurchaseTime;
        uint256 deadline; // needs to be far away, may be calculated for max number of purchases needed
    }

    // --------------- //
    // STATE VARIABLES //
    // --------------- //

    /// @notice Quote Token, expected to be a stablecoin
    address public immutable quoteToken;

    /// @notice Uniswap router adapter
    address public immutable uniswapAdapter;

    /// @notice Uniswap router
    address public immutable router;

    /// @notice Pending orders.
    mapping(uint256 => Order) public orders;

    /// @notice Signature nonces for EIP712 replay protection.
    mapping(address => uint256) public signatureNonce;

    /// @notice Orders counter.
    uint256 internal _nextOrderId;

    /// @notice Slippage controls - max 1 percent.
    uint256 public constant slippageCoefficient = 9900;
    uint256 public constant slippageDenominator = 10000;

    /// @notice EIP-712 type hashes
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address borrower,address manager,address account,address tokenOut,uint256 budget,uint256 interval,uint256 amountPerInterval,uint256 deadline,uint256 nonce)"
    );
    bytes32 public constant CANCEL_ORDER_TYPEHASH = keccak256("CancelOrder(uint256 orderId)");

    // ------ //
    // EVENTS //
    // ------ //

    /// @notice Emitted when user submits a new DCA order.
    /// @param user User that submitted the order.
    /// @param orderId ID of the created order.
    event CreateOrder(address indexed user, uint256 indexed orderId);

    /// @notice Emitted when user cancels the order.
    /// @param user User that canceled the order.
    /// @param orderId ID of the canceled order.
    event CancelOrder(address indexed user, uint256 indexed orderId);

    /// @notice Emitted when DCA order is successfully executed.
    /// @param executor Account that executed the order.
    /// @param orderId ID of the executed order.
    /// @param amountPurchased Amount of tokenOut purchased.
    event PurchaseCompleted(address indexed executor, uint256 indexed orderId, uint256 amountPurchased);

    /// @notice Emitted when DCA order is fully completed.
    /// @param executor Account that executed the order.
    /// @param orderId ID of the executed order.
    /// @param amountPurchased Amount of tokenOut purchased this execution.
    /// @param totalSpend Amount of tokenOut purchased this execution.
    event OrderCompleted(
        address indexed executor, uint256 indexed orderId, uint256 amountPurchased, uint256 totalSpend
    );

    /// @notice Emitted when DCA order is reset after a large price swing.
    /// @param user User that reset the order.
    /// @param orderId ID of the reset order.
    event ResetOrder(address indexed user, uint256 indexed orderId);

    // ------ //
    // ERRORS //
    // ------ //

    /// @notice When user tries to submit/cancel other user's order.
    error CallerNotBorrower();

    /// @notice When order can't be executed because it's cancelled.
    error OrderIsCancelled();

    /// @notice When order can't be executed because it's incorrect.
    error InvalidOrder();

    /// @notice When trying to execute order after deadline.
    error Expired();

    /// @notice When the credit account's owner changed between order submission and execution.
    error CreditAccountBorrowerChanged();

    /// @notice When trying to execute order before the interval has passed.
    error IntervalNotPassed();

    /// @notice When the price swing is too large to execute the order.
    error PriceSwingTooLarge();

    /// @notice When the signature nonce doesn't correspond to current counter.
    error IncorrectSignatureNonce();

    // ----------- //
    // CONSTRUCTOR //
    // ----------- //

    constructor(address quoteToken_, address uniswapAdapter_, address router_) EIP712("DCABot", "1") {
        require(quoteToken_ != address(0));
        require(uniswapAdapter_ != address(0));
        require(router_ != address(0));

        quoteToken = quoteToken_;
        uniswapAdapter = uniswapAdapter_;
        router = router_;
    }

    // ------------------ //
    // EXTERNAL FUNCTIONS //
    // ------------------ //

    /// @notice Submit new DCA order.
    /// @param order Order to submit.
    /// @return orderId ID of created order.
    function submitOrder(Order calldata order) external returns (uint256 orderId) {
        // U:[DCA-02]
        if (
            order.borrower != msg.sender
                || ICreditManagerV3(order.manager).getBorrowerOrRevert(order.account) != order.borrower
        ) {
            revert CallerNotBorrower();
        }
        return _createOrder(order);
    }

    /// @notice Submit new DCA order with EIP-712 signature.
    /// @param order Order to submit.
    /// @param signature EIP-712 signature of the order.
    /// @return orderId ID of created order.
    function submitOrderWithSignature(Order calldata order, uint256 nonce, bytes memory signature)
        external
        returns (uint256 orderId)
    {
        bytes32 orderHash = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    order.borrower,
                    order.manager,
                    order.account,
                    order.tokenOut,
                    order.budget,
                    order.interval,
                    order.amountPerInterval,
                    order.deadline,
                    nonce
                )
            )
        );

        address signer = ECDSA.recover(orderHash, signature);
        uint256 expectedNonce = _useSignatureNonce(signer);
        if (expectedNonce != nonce) {
            revert IncorrectSignatureNonce();
        }

        // U:[DCA-02]
        if (
            order.borrower != signer
                || ICreditManagerV3(order.manager).getBorrowerOrRevert(order.account) != order.borrower
        ) {
            revert CallerNotBorrower();
        }
        return _createOrder(order);
    }

    /// @notice Creates new DCA order assuming borrower already verified.
    /// @param order Order to submit.
    /// @return orderId ID of created order.
    function _createOrder(Order calldata order) internal returns (uint256 orderId) {
        // U:[DCA-08]
        if (
            quoteToken == order.tokenOut || order.amountPerInterval == 0 || order.interval == 0 || order.totalSpend != 0
        ) {
            revert InvalidOrder();
        }
        orderId = _useOrderId();
        orders[orderId] = order;

        Order storage storedOrder = orders[orderId];
        storedOrder.lastPrice =
            getCurrentPrice(ICreditManagerV3(storedOrder.manager).priceOracle(), storedOrder.tokenOut);

        emit CreateOrder(order.borrower, orderId);
    }

    /// @notice Cancel pending order.
    /// @param orderId ID of order to cancel.
    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];
        // U:[DCA-04]
        if (order.borrower != msg.sender) {
            revert CallerNotBorrower();
        }
        delete orders[orderId];
        emit CancelOrder(msg.sender, orderId);
    }

    /// @notice Cancel pending order with EIP-712 signature.
    /// @param orderId ID of order to cancel.
    /// @param signature EIP-712 signature for the cancel operation.
    function cancelOrderWithSignature(uint256 orderId, bytes memory signature) external {
        Order storage order = orders[orderId];
        require(order.borrower != address(0), "Order does not exist");

        bytes32 cancelHash = _hashTypedDataV4(keccak256(abi.encode(CANCEL_ORDER_TYPEHASH, orderId)));

        address signer = ECDSA.recover(cancelHash, signature);
        // U:[DCA-04_1]
        if (order.borrower != signer) {
            revert CallerNotBorrower();
        }

        address borrower = order.borrower;
        delete orders[orderId];
        emit CancelOrder(borrower, orderId);
    }

    /// @notice Execute given DCA order.
    /// @param orderId ID of order to execute.
    function executeOrder(uint256 orderId) external {
        Order storage order = orders[orderId];

        (uint256 minAmountOut, uint256 currentPrice) = _validateOrder(order);

        IERC20(quoteToken).approve(router, order.amountPerInterval * 100);

        address facade = ICreditManagerV3(order.manager).creditFacade();

        ISwapRouter.ExactInputSingleParams memory exactInputSingleParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: quoteToken,
            tokenOut: order.tokenOut,
            fee: 500,
            recipient: order.account,
            deadline: block.timestamp + 3600,
            amountIn: order.amountPerInterval,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: uniswapAdapter,
            callData: abi.encodeCall(IUniswapV3Adapter.exactInputSingle, exactInputSingleParams)
        });

        ICreditFacadeV3(facade).botMulticall(order.account, calls);

        order.lastPurchaseTime = block.timestamp;
        order.totalSpend += order.amountPerInterval;
        order.lastPrice = currentPrice;

        emit PurchaseCompleted(msg.sender, orderId, minAmountOut);
        if (order.totalSpend >= order.budget) {
            delete orders[orderId];
            emit OrderCompleted(msg.sender, orderId, minAmountOut, order.totalSpend);
        }
    }

    /// @notice Reset the order after a large price swing.
    /// @param orderId ID of order to reset.
    // U:[DCA-14]
    function resetOrder(uint256 orderId) external {
        Order storage order = orders[orderId];
        if (order.borrower != msg.sender) {
            revert CallerNotBorrower();
        }
        order.lastPrice = getCurrentPrice(ICreditManagerV3(order.manager).priceOracle(), order.tokenOut);
        emit ResetOrder(msg.sender, orderId);
    }

    // ------------------ //
    // INTERNAL FUNCTIONS //
    // ------------------ //

    /// @dev Increments the order counter and returns its previous value.
    function _useOrderId() internal returns (uint256 orderId) {
        orderId = _nextOrderId;
        _nextOrderId = orderId + 1;
    }

    /// @dev Increments the signature nonce for the signer and returns its previous value.
    function _useSignatureNonce(address signer) internal returns (uint256 nonce) {
        nonce = signatureNonce[signer];
        signatureNonce[signer] = nonce + 1;
    }

    /// @dev Get current price from the price oracle per 1 quote token.
    function getCurrentPrice(address oracle, address tokenOut) public view returns (uint256) {
        IPriceOracleV3 oracleContract = IPriceOracleV3(oracle);
        uint256 ONE = 10 ** IERC20Metadata(quoteToken).decimals();
        return oracleContract.convert(ONE, quoteToken, tokenOut);
    }

    /// @dev Checks if the price swing is within acceptable range (10%).
    function isPriceSwingAcceptable(uint256 lastPrice, uint256 currentPrice) internal pure returns (bool) {
        uint256 swingPercentage = abs(int256(currentPrice) - int256(lastPrice)) * 100 / lastPrice;
        return swingPercentage <= 10;
    }

    /// @dev Calculate absolute value.
    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    /// @dev Checks if order can be executed:
    ///      * order must be correctly constructed and not expired;
    ///      * trigger condition must hold if trigger price is set;
    ///      * borrower must have an account in manager with non-empty input token balance.
    function _validateOrder(Order memory order) internal view returns (uint256 minAmountOut, uint256 currentPrice) {
        // U:[DCA-06]
        if (order.account == address(0)) {
            revert OrderIsCancelled();
        }

        ICreditManagerV3 manager = ICreditManagerV3(order.manager);

        // U:[DCA-07]
        if (manager.getBorrowerOrRevert(order.account) != order.borrower) {
            revert CreditAccountBorrowerChanged();
        }

        // U:[DCA-09] - applies only when the deadline is set
        if (order.deadline > 0 && block.timestamp > order.deadline) {
            revert Expired();
        }

        if (order.lastPurchaseTime > 0 && block.timestamp < order.lastPurchaseTime + order.interval) {
            revert IntervalNotPassed();
        }

        currentPrice = getCurrentPrice(manager.priceOracle(), order.tokenOut);

        // U:[DCA-10]
        if (!isPriceSwingAcceptable(order.lastPrice, currentPrice)) {
            revert PriceSwingTooLarge();
        }

        if (order.budget > 0 && order.totalSpend + order.amountPerInterval > order.budget) {
            order.amountPerInterval = order.budget - order.totalSpend;
        }

        minAmountOut = (order.amountPerInterval * currentPrice * slippageCoefficient)
            / (10 ** IERC20Metadata(quoteToken).decimals() * slippageDenominator);
    }

    /// @dev EIP712 domain separator
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
