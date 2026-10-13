// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.24;

import { StablecoinDEX } from "../src/StablecoinDEX.sol";
import { StablecoinDEXInvariantTest } from "./spec/invariants/StablecoinDEX.t.sol";
import { StablecoinDEXTest } from "./spec/StablecoinDEX.t.sol";
import { IStablecoinDEX } from "tempo-std/interfaces/IStablecoinDEX.sol";

/// Tempo's DEX spec suite, run against the Solidity port instead of the precompile.
contract PortStablecoinDEXTest is StablecoinDEXTest {

    function setUp() public override {
        exchange = IStablecoinDEX(address(new StablecoinDEX()));
        super.setUp();
    }

    function test_ExchangeIsPort() public view {
        assertTrue(address(exchange) != STABLE_DEX);
        assertGt(address(exchange).code.length, 1000);
    }

}

/// Tempo's DEX invariant suite, run against the Solidity port instead of the precompile.
contract PortStablecoinDEXInvariantTest is StablecoinDEXInvariantTest {

    function setUp() public override {
        exchange = IStablecoinDEX(address(new StablecoinDEX()));
        super.setUp();
    }

}
