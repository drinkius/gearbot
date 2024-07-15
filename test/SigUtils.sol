// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DCABot} from "../contracts/DCABot.sol";

contract SigUtils {
    bytes32 internal DOMAIN_SEPARATOR;

    constructor(bytes32 _DOMAIN_SEPARATOR) {
        DOMAIN_SEPARATOR = _DOMAIN_SEPARATOR;
    }

    /// @notice EIP-712 type hashes
    // keccak256("Order(address borrower,address manager,address account,address tokenOut,uint256 budget,uint256 interval,uint256 amountPerInterval,uint256 deadline,uint256 nonce)");
    bytes32 public constant ORDER_TYPEHASH = 0x78ae30ec50a2fca907ccc077c47ab1e61d784b51ed8040631662139b5c419925;
    // keccak256("CancelOrder(uint256 orderId)");
    bytes32 public constant CANCEL_ORDER_TYPEHASH = 0x8e845176a8c53dbc1df7d8dc731160c4bc9898b982e14e91efc5334019c3290c;

    // computes the hash of an order
    function getOrderHash(DCABot.Order memory _order, uint256 _nonce) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                _order.borrower,
                _order.manager,
                _order.account,
                _order.tokenOut,
                _order.budget,
                _order.interval,
                _order.amountPerInterval,
                _order.deadline,
                _nonce
            )
        );
    }

    // computes the hash of an order
    function getCancelOrderHash(uint256 orderId) internal pure returns (bytes32) {
        return keccak256(abi.encode(CANCEL_ORDER_TYPEHASH, orderId));
    }

    // computes the hash of the fully encoded EIP-712 message for the domain, which can be used to recover the signer
    function getTypeOrderdDataHash(DCABot.Order memory _order, uint256 _nonce) public view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, getOrderHash(_order, _nonce)));
    }

    function getTypeCancelOrderDataHash(uint256 orderId) public view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, getCancelOrderHash(orderId)));
    }
}
