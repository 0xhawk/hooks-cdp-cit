// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";

import "./CDPManager.sol";
import "./CryptoIndexToken.sol";

contract CDPHook is BaseHook {
    CDPManager public immutable cdpManager;
    CryptoIndexToken public immutable cit;

    constructor(
        IPoolManager _manager,
        address _cdpManager,
        address _cit
    ) BaseHook(_manager) {
        cdpManager = CDPManager(_cdpManager);
        cit = CryptoIndexToken(_cit);
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        // Assume USDC is token0 and CIT is token1
        // Check if the pool is the USDC/CIT pool
        if (
            Currency.unwrap(key.currency0) != address(cdpManager.usdc()) ||
            Currency.unwrap(key.currency1) != address(cit)
        ) {
            return (this.afterAddLiquidity.selector, delta);
        }

        uint256 usdcAmount = uint256(int256(-delta.amount0()));

        // Call depositAndMint on the CDP Manager
        // This will mint CIT and update the user's position
        cdpManager.depositAndMintFromHook(sender, usdcAmount);

        return (this.afterAddLiquidity.selector, delta);
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, int128) {
        // No custom logic for swaps in this simplified version
        return (this.afterSwap.selector, 0);
    }
}
