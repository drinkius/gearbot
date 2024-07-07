// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {DCABot} from "../contracts/DCABot.sol";

contract CounterTest is Test {
    DCABot public bot;

    function setUp() public {
        bot = new DCABot();
    }
}
