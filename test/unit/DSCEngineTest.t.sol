// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import { DeployTSC } from "../../script/DeployTSC.s.sol";
import { TSCEngine } from "../../src/TSCEngine.sol";
import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";
import { HelperConfig } from "../../script/HelperConfig.s.sol";
// import { ERC20Mock } from "@openzeppelin/contracts/mocks/ERC20Mock.sol"; Updated mock location
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { MockV3Aggregator } from "../mocks/MockV3Aggregator.sol";
import { MockMoreDebtTSC } from "../mocks/MockMoreDebtTSC.sol";
import { MockFailedMintTSC } from "../mocks/MockFailedMintTSC.sol";
import { MockFailedTransferFrom } from "../mocks/MockFailedTransferFrom.sol";
import { MockFailedTransfer } from "../mocks/MockFailedTransfer.sol";
import { Test, console } from "forge-std/Test.sol";
import { StdCheats } from "forge-std/StdCheats.sol";

contract TSCEngineTest is StdCheats, Test {
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if
        // redeemFrom != redeemedTo, then it was liquidated

    TSCEngine public TSCe;
    DecentralizedStableCoin public TSC;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;
    address public user = address(1);

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() external {
        DeployTSC deployer = new DeployTSC();
        (TSC, TSCe, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();
        if (block.chainid == 31_337) {
            vm.deal(user, STARTING_USER_BALANCE);
        }
        // Should we put our integration tests here?
        // else {
        //     user = vm.addr(deployerKey);
        //     ERC20Mock mockErc = new ERC20Mock("MOCK", "MOCK", user, 100e18);
        //     MockV3Aggregator aggregatorMock = new MockV3Aggregator(
        //         helperConfig.DECIMALS(),
        //         helperConfig.ETH_USD_PRICE()
        //     );
        //     vm.etch(weth, address(mockErc).code);
        //     vm.etch(wbtc, address(mockErc).code);
        //     vm.etch(ethUsdPriceFeed, address(aggregatorMock).code);
        //     vm.etch(btcUsdPriceFeed, address(aggregatorMock).code);
        // }
        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(user, STARTING_USER_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public feedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(TSCEngine.TSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch.selector);
        new TSCEngine(tokenAddresses, feedAddresses, address(TSC));
    }

    //////////////////
    // Price Tests //
    //////////////////

    function testGetTokenAmountFromUsd() public {
        // If we want $100 of WETH @ $2000/WETH, that would be 0.05 WETH
        uint256 expectedWeth = 0.05 ether;
        uint256 amountWeth = TSCe.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(amountWeth, expectedWeth);
    }

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 ETH * $2000/ETH = $30,000e18
        uint256 expectedUsd = 30_000e18;
        uint256 usdValue = TSCe.getUsdValue(weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    ///////////////////////////////////////
    // depositCollateral Tests //
    ///////////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockTSC = new MockFailedTransferFrom();
        tokenAddresses = [address(mockTSC)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        TSCEngine mockTSCe = new TSCEngine(tokenAddresses, feedAddresses, address(mockTSC));
        mockTSC.mint(user, amountCollateral);

        vm.prank(owner);
        mockTSC.transferOwnership(address(mockTSCe));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockTSC)).approve(address(mockTSCe), amountCollateral);
        // Act / Assert
        vm.expectRevert(TSCEngine.TSCEngine__TransferFailed.selector);
        mockTSCe.depositCollateral(address(mockTSC), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(TSCe), amountCollateral);

        vm.expectRevert(TSCEngine.TSCEngine__NeedsMoreThanZero.selector);
        TSCe.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", user, 100e18);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(TSCEngine.TSCEngine__TokenNotAllowed.selector, address(randToken)));
        TSCe.depositCollateral(address(randToken), amountCollateral);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(TSCe), amountCollateral);
        TSCe.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = TSC.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalTSCMinted, uint256 collateralValueInUsd) = TSCe.getAccountInformation(user);
        uint256 expectedDepositedAmount = TSCe.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalTSCMinted, 0);
        assertEq(expectedDepositedAmount, amountCollateral);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintTSC Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedTSCBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * TSCe.getAdditionalFeedPrecision())) / TSCe.getPrecision();
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(TSCe), amountCollateral);

        uint256 expectedHealthFactor =
            TSCe.calculateHealthFactor(amountToMint, TSCe.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(TSCEngine.TSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        TSCe.depositCollateralAndMintTSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedTSC() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(TSCe), amountCollateral);
        TSCe.depositCollateralAndMintTSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedTSC {
        uint256 userBalance = TSC.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // mintTSC Tests //
    ///////////////////////////////////
    // This test needs it's own custom setup
    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintTSC mockTSC = new MockFailedMintTSC();
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        TSCEngine mockTSCe = new TSCEngine(tokenAddresses, feedAddresses, address(mockTSC));
        mockTSC.transferOwnership(address(mockTSCe));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockTSCe), amountCollateral);

        vm.expectRevert(TSCEngine.TSCEngine__MintFailed.selector);
        mockTSCe.depositCollateralAndMintTSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(TSCe), amountCollateral);
        TSCe.depositCollateralAndMintTSC(weth, amountCollateral, amountToMint);
        vm.expectRevert(TSCEngine.TSCEngine__NeedsMoreThanZero.selector);
        TSCe.mintTSC(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * TSCe.getAdditionalFeedPrecision())) / TSCe.getPrecision();

        vm.startPrank(user);
        uint256 expectedHealthFactor =
            TSCe.calculateHealthFactor(amountToMint, TSCe.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(TSCEngine.TSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        TSCe.mintTSC(amountToMint);
        vm.stopPrank();
    }

    function testCanMintTSC() public depositedCollateral {
        vm.prank(user);
        TSCe.mintTSC(amountToMint);

        uint256 userBalance = TSC.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // burnTSC Tests //
    ///////////////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(TSCe), amountCollateral);
        TSCe.depositCollateralAndMintTSC(weth, amountCollateral, amountToMint);
        vm.expectRevert(TSCEngine.TSCEngine__NeedsMoreThanZero.selector);
        TSCe.burnTSC(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(user);
        vm.expectRevert();
        TSCe.burnTSC(1);
    }

    function testCanBurnTSC() public depositedCollateralAndMintedTSC {
        vm.startPrank(user);
        TSC.approve(address(TSCe), amountToMint);
        TSCe.burnTSC(amountToMint);
        vm.stopPrank();

        uint256 userBalance = TSC.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////
    // redeemCollateral Tests //
    //////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockTSC = new MockFailedTransfer();
        tokenAddresses = [address(mockTSC)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        TSCEngine mockTSCe = new TSCEngine(tokenAddresses, feedAddresses, address(mockTSC));
        mockTSC.mint(user, amountCollateral);

        vm.prank(owner);
        mockTSC.transferOwnership(address(mockTSCe));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockTSC)).approve(address(mockTSCe), amountCollateral);
        // Act / Assert
        mockTSCe.depositCollateral(address(mockTSC), amountCollateral);
        vm.expectRevert(TSCEngine.TSCEngine__TransferFailed.selector);
        mockTSCe.redeemCollateral(address(mockTSC), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(TSCe), amountCollateral);
        TSCe.depositCollateralAndMintTSC(weth, amountCollateral, amountToMint);
        vm.expectRevert(TSCEngine.TSCEngine__NeedsMoreThanZero.selector);
        TSCe.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(user);
        uint256 userBalanceBeforeRedeem = TSCe.getCollateralBalanceOfUser(user, weth);
        assertEq(userBalanceBeforeRedeem, amountCollateral);
        TSCe.redeemCollateral(weth, amountCollateral);
        uint256 userBalanceAfterRedeem = TSCe.getCollateralBalanceOfUser(user, weth);
        assertEq(userBalanceAfterRedeem, 0);
        vm.stopPrank();
    }


    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(TSCe));
        emit CollateralRedeemed(user, user, weth, amountCollateral);
        vm.startPrank(user);
        TSCe.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();
    }
    ///////////////////////////////////
    // redeemCollateralForTSC Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedTSC {
        vm.startPrank(user);
        TSC.approve(address(TSCe), amountToMint);
        vm.expectRevert(TSCEngine.TSCEngine__NeedsMoreThanZero.selector);
        TSCe.redeemCollateralForTSC(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(TSCe), amountCollateral);
        TSCe.depositCollateralAndMintTSC(weth, amountCollateral, amountToMint);
        TSC.approve(address(TSCe), amountToMint);
        TSCe.redeemCollateralForTSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = TSC.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedTSC {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = TSCe.getHealthFactor(user);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedTSC {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Remember, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = TSCe.getHealthFactor(user);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalTSCMinted) =
        // 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    // This test needs it's own setup
    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtTSC mockTSC = new MockMoreDebtTSC(ethUsdPriceFeed);
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        TSCEngine mockTSCe = new TSCEngine(tokenAddresses, feedAddresses, address(mockTSC));
        mockTSC.transferOwnership(address(mockTSCe));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockTSCe), amountCollateral);
        mockTSCe.depositCollateralAndMintTSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockTSCe), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockTSCe.depositCollateralAndMintTSC(weth, collateralToCover, amountToMint);
        mockTSC.approve(address(mockTSCe), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(TSCEngine.TSCEngine__HealthFactorNotImproved.selector);
        mockTSCe.liquidate(weth, user, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedTSC {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(TSCe), collateralToCover);
        TSCe.depositCollateralAndMintTSC(weth, collateralToCover, amountToMint);
        TSC.approve(address(TSCe), amountToMint);

        vm.expectRevert(TSCEngine.TSCEngine__HealthFactorOk.selector);
        TSCe.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(TSCe), amountCollateral);
        TSCe.depositCollateralAndMintTSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = TSCe.getHealthFactor(user);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(TSCe), collateralToCover);
        TSCe.depositCollateralAndMintTSC(weth, collateralToCover, amountToMint);
        TSC.approve(address(TSCe), amountToMint);
        TSCe.liquidate(weth, user, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = TSCe.getTokenAmountFromUsd(weth, amountToMint)
            + (TSCe.getTokenAmountFromUsd(weth, amountToMint) * TSCe.getLiquidationBonus() / TSCe.getLiquidationPrecision());
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = TSCe.getTokenAmountFromUsd(weth, amountToMint)
            + (TSCe.getTokenAmountFromUsd(weth, amountToMint) * TSCe.getLiquidationBonus() / TSCe.getLiquidationPrecision());

        uint256 usdAmountLiquidated = TSCe.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = TSCe.getUsdValue(weth, amountCollateral) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = TSCe.getAccountInformation(user);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorTSCMinted,) = TSCe.getAccountInformation(liquidator);
        assertEq(liquidatorTSCMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userTSCMinted,) = TSCe.getAccountInformation(user);
        assertEq(userTSCMinted, 0);
    }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = TSCe.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = TSCe.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = TSCe.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = TSCe.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = TSCe.getAccountInformation(user);
        uint256 expectedCollateralValue = TSCe.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(TSCe), amountCollateral);
        TSCe.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralBalance = TSCe.getCollateralBalanceOfUser(user, weth);
        assertEq(collateralBalance, amountCollateral);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(TSCe), amountCollateral);
        TSCe.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralValue = TSCe.getAccountCollateralValue(user);
        uint256 expectedCollateralValue = TSCe.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetTSC() public {
        address TSCAddress = TSCe.getTSC();
        assertEq(TSCAddress, address(TSC));
    }

    function testLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = TSCe.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }

    // How do we adjust our invariant tests for this?
    // function testInvariantBreaks() public depositedCollateralAndMintedTSC {
    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(0);

    //     uint256 totalSupply = TSC.totalSupply();
    //     uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(TSCe));
    //     uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(TSCe));

    //     uint256 wethValue = TSCe.getUsdValue(weth, wethDeposted);
    //     uint256 wbtcValue = TSCe.getUsdValue(wbtc, wbtcDeposited);

    //     console.log("wethValue: %s", wethValue);
    //     console.log("wbtcValue: %s", wbtcValue);
    //     console.log("totalSupply: %s", totalSupply);

    //     assert(wethValue + wbtcValue >= totalSupply);
    // }
}
