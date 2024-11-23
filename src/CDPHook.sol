// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import "./CDPManager.sol";
import "forge-std/console.sol";

contract CDPHook is BaseHook {
    using CurrencySettler for Currency;
    CDPManager public cdpManager;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    // Function to set CDP Manager after deployment
    function setCDPManager(address _cdpManager) external {
        require(address(cdpManager) == address(0), "CDP Manager already set");
        cdpManager = CDPManager(_cdpManager);
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
                afterInitialize: true,
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

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) external override onlyPoolManager returns (bytes4) {
        console.log("AFTER INITIALIZE");
        // TODO: salt from args
        bytes32 salt = keccak256(abi.encodePacked("unique_identifier"));
        cdpManager.initialize(salt);
        return this.afterInitialize.selector;
    }

    struct CallbackData {
        uint256 amount0;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    function addLiquidity(PoolKey calldata key, uint256 amount0) external {
        poolManager.unlock(
            abi.encode(
                CallbackData(amount0, key.currency0, key.currency1, msg.sender)
            )
        );
    }

    function _unlockCallback(
        bytes calldata data
    ) internal override returns (bytes memory) {
        console.log("CALL BACK");
        CallbackData memory callbackData = abi.decode(data, (CallbackData));
        uint256 collateralAmount = callbackData.amount0 / 2; // 50% to be collateral
        uint256 debtAmount = cdpManager.depositAndMint(callbackData.sender, collateralAmount);
        console.log(debtAmount);

        // TODO: add liquidity
        

        return "";
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        console.log("AFTER ADD LIQUIDITY");
        console.log(delta.amount0());
        console.log(delta.amount1());
        // Assume USDC is token0 and CIT is token1
        // Check if the pool is the USDC/CIT pool
        // if (
        //     Currency.unwrap(key.currency0) != address(cdpManager.usdc()) ||
        //     Currency.unwrap(key.currency1) != address(cit)
        // ) {
        //     return (this.afterAddLiquidity.selector, delta);
        // }

        // // Determine the amount of USDC added
        // uint256 usdcAmount;
        // if (delta.amount0() < 0) {
        //     // User added USDC to the pool
        //     usdcAmount = uint256(int256(-delta.amount0()));
        // } else {
        //     // No USDC added; possibly a removal of liquidity
        //     usdcAmount = 0;
        // }

        // // Proceed only if usdcAmount is greater than zero
        // if (usdcAmount > 0) {
        //     // Call depositAndMintFromHook on the CDP Manager
        //     cdpManager.depositAndMintFromHook(sender, usdcAmount);
        // }

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
