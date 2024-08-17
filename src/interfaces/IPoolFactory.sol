// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.20;

// fine ✅

interface IPoolFactory {
    // fetches the pool address for a given token
    function getPool(address tokenAddress) external view returns (address);
}
