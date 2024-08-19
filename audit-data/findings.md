[H-2] Unnecessary updateExchangeRate in deposit function incorrectly updates exchangeRate preventing withdraws and unfairly changing reward distribution

Description:

```js
    function deposit(IERC20 token, uint256 amount) external revertIfZero(amount) revertIfNotAllowedToken(token) {
        AssetToken assetToken = s_tokenToAssetToken[token];
        uint256 exchangeRate = assetToken.getExchangeRate();
        uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
        emit Deposit(msg.sender, token, amount);
        assetToken.mint(msg.sender, mintAmount);
        uint256 calculatedFee = getCalculatedFee(token, amount);
        assetToken.updateExchangeRate(calculatedFee);
        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }
```

- the exchange rate between Atokens and its underlying token is a way to keep track of the fees accrued from teh users doing `flashLoans` and these fees need to be paid to the LP during redemption
- since it only makes sense to updte the X-rate when fees are collected by the protocol during the flashLoans, therefore, updating them during the deposit func makes no sense and hence fools the protocol into thinking that it has more fees that it actually does, hecne breking teh redemption funcionlaity


Impact: Breaks the redemption function of the protocol; LP get more tokens then they deposited.

Proof of Concept:

````js

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


        assertEq(tokenA.balanceOf(liquidityProvider), amountToRedeemInUnderlying);
        // comes out to be 100330090000000000000
        // when it should be 100030000000000000000 

    }
```js

