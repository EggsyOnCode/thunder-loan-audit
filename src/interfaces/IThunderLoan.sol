// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

//@audit-info interface not being implemented by `Thunderloan.sol`
interface IThunderLoan {
    function repay(address token, uint256 amount) external;
}
