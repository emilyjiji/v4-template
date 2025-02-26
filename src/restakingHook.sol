// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RestakingHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // -----------------------------------------------
    // Schema Definition
    // -----------------------------------------------

    // Struct to represent a user's liquidity position
    struct Position {
        uint256 liquidityTokens; // Number of liquidity tokens held
        int24 lowerTick; // Lower bound of the range
        int24 upperTick; // Upper bound of the range
        uint256 lpFees; // LP fees earned
        uint256 p2pRewards; // P2P restaking rewards
        uint256 lastUpdated; // Timestamp of last update
    }

    // Struct to represent pool-specific data
    struct PoolData {
        uint256 totalLiquidity; // Total liquidity in the pool
        mapping(int24 => mapping(int24 => bool)) inactiveRanges; // Tracks inactive ranges
    }

    // Mapping to store user positions
    mapping(address => Position[]) public userPositions;

    // Mapping to store pool-specific data
    mapping(PoolId => PoolData) public poolData;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // -----------------------------------------------
    // Hook Functions
    // -----------------------------------------------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false, // Disabled for now
            afterSwap: false,  // Disabled for now
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeAddLiquidity(
        address user,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        // Transfer tokens from the user to this contract
        _transferTokens(user, key.currency0, params.amount0);
        _transferTokens(user, key.currency1, params.amount1);

        // Create a new position for the user
        Position memory newPosition = Position({
            liquidityTokens: params.liquidityDelta, // Simplified for demonstration
            lowerTick: params.tickLower,
            upperTick: params.tickUpper,
            lpFees: 0,
            p2pRewards: 0,
            lastUpdated: block.timestamp
        });

        // Add the position to the user's array
        userPositions[user].push(newPosition);

        // Update pool data
        PoolData storage pool = poolData[key.toId()];
        pool.totalLiquidity += params.liquidityDelta;

        return BaseHook.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address user,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        // Find the user's position that matches the range
        Position[] storage positions = userPositions[user];
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].lowerTick == params.tickLower && positions[i].upperTick == params.tickUpper) {
                // Transfer tokens back to the user
                _transferTokens(address(this), user, key.currency0, params.amount0);
                _transferTokens(address(this), user, key.currency1, params.amount1);

                // Update the position
                positions[i].liquidityTokens -= params.liquidityDelta;
                positions[i].lastUpdated = block.timestamp;

                // If the position is fully withdrawn, remove it from the array
                if (positions[i].liquidityTokens == 0) {
                    positions[i] = positions[positions.length - 1];
                    positions.pop();
                }

                // Update pool data
                PoolData storage pool = poolData[key.toId()];
                pool.totalLiquidity -= params.liquidityDelta;

                break;
            }
        }

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // -----------------------------------------------
    // Internal Helper Functions
    // -----------------------------------------------

    /// @dev Transfers tokens from `from` to `to`
    function _transferTokens(address from, address to, Currency currency, uint256 amount) internal {
        if (currency.isNative()) {
            // Handle native ETH transfers
            require(address(this).balance >= amount, "Insufficient ETH balance");
            (bool success,) = to.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            // Handle ERC20 token transfers
            IERC20(Currency.unwrap(currency)).transferFrom(from, to, amount);
        }
    }

    // -----------------------------------------------
    // Custom Logic for Inactive Liquidity Ranges
    // -----------------------------------------------

    /// @dev Marks a liquidity range as inactive
    function markRangeInactive(PoolKey calldata key, int24 lowerTick, int24 upperTick) external {
        PoolData storage pool = poolData[key.toId()];
        pool.inactiveRanges[lowerTick][upperTick] = true;
    }

    /// @dev Marks a liquidity range as active
    function markRangeActive(PoolKey calldata key, int24 lowerTick, int24 upperTick) external {
        PoolData storage pool = poolData[key.toId()];
        pool.inactiveRanges[lowerTick][upperTick] = false;
    }

    /// @dev Checks if a liquidity range is inactive
    function isRangeInactive(PoolKey calldata key, int24 lowerTick, int24 upperTick) external view returns (bool) {
        PoolData storage pool = poolData[key.toId()];
        return pool.inactiveRanges[lowerTick][upperTick];
    }

    // -----------------------------------------------
    // Restaking Logic (Placeholder)
    // -----------------------------------------------

    /// @dev Restakes inactive liquidity on P2P
    function restakeInactiveLiquidity(PoolKey calldata key, int24 lowerTick, int24 upperTick) external {
        require(isRangeInactive(key, lowerTick, upperTick), "Range is not inactive");

        // TODO: Implement restaking logic using P2P API
        // Example: Withdraw liquidity from Uniswap and restake on P2P
    }

    /// @dev Moves liquidity back to the pool when the range becomes active
    function moveLiquidityBackToPool(PoolKey calldata key, int24 lowerTick, int24 upperTick) external {
        require(!isRangeInactive(key, lowerTick, upperTick), "Range is still inactive");

        // TODO: Implement logic to move liquidity back to the pool
        // Example: Withdraw from P2P and deposit back into Uniswap
    }
}