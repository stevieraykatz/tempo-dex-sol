// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.0;

import {IStablecoinDEX} from "tempo-std/interfaces/IStablecoinDEX.sol";

import {StablecoinDEX} from "../src/StablecoinDEX.sol";

import {StablecoinDEXTest} from "./spec/StablecoinDEX.t.sol";
import {StablecoinDEXInvariantTest} from "./spec/invariants/StablecoinDEX.t.sol";

/// @notice Tempo's DEX spec suite, run against the port instead of the precompile.
contract PortStablecoinDEXTest is StablecoinDEXTest {
    function setUp() public override {
        exchange = IStablecoinDEX(address(new StablecoinDEX()));
        super.setUp();
    }

    function test_setUp_pointsExchangeAtPort() public view {
        assertTrue(address(exchange) != STABLE_DEX);
        assertGt(address(exchange).code.length, 0);
    }
}

/// @notice Tempo's DEX invariant suite, run against the port instead of the precompile.
contract PortStablecoinDEXInvariantTest is StablecoinDEXInvariantTest {
    function setUp() public override {
        exchange = IStablecoinDEX(address(new StablecoinDEX()));
        super.setUp();
    }
}
