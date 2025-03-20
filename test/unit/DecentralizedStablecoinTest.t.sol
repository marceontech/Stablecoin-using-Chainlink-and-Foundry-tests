// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";
import { Test, console } from "forge-std/Test.sol";
import { StdCheats } from "forge-std/StdCheats.sol";

contract DecentralizedStablecoinTest is StdCheats, Test {
    DecentralizedStableCoin TSC;

    function setUp() public {
        TSC = new DecentralizedStableCoin();
    }

    function testMustMintMoreThanZero() public {
        vm.prank(TSC.owner());
        vm.expectRevert();
        TSC.mint(address(this), 0);
    }

    function testMustBurnMoreThanZero() public {
        vm.startPrank(TSC.owner());
        TSC.mint(address(this), 100);
        vm.expectRevert();
        TSC.burn(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanYouHave() public {
        vm.startPrank(TSC.owner());
        TSC.mint(address(this), 100);
        vm.expectRevert();
        TSC.burn(101);
        vm.stopPrank();
    }

    function testCantMintToZeroAddress() public {
        vm.startPrank(TSC.owner());
        vm.expectRevert();
        TSC.mint(address(0), 100);
        vm.stopPrank();
    }
}
