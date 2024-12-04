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
import "forge-std/interfaces/IERC20.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

contract CDPHook is BaseHook {
    using CurrencySettler for Currency;

    error AddLiquidityThroughHook(); // error to throw when someone tries adding liquidity directly to the PoolManager

    CDPManager public cdpManager;
    PoolKey public poolKey;

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
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
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
        poolKey = key; // Store the poolKey for later use
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
        // Transfer USDC from user to Hook
        IERC20(address(cdpManager.collateralToken())).transferFrom(
            msg.sender,
            address(this),
            amount0
        );
        poolManager.unlock(
            abi.encode(
                CallbackData(amount0, key.currency0, key.currency1, msg.sender)
            )
        );
    }

    function _unlockCallback(
        bytes calldata data
    ) internal override returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // Mint synthetic tokens to the Hook contract and update user's position
        uint256 syntheticTokenAmount = cdpManager.mintAndDeposit(
            address(this),
            callbackData.sender,
            callbackData.amount0
        );

        // Now the Hook has both USDC and synthetic tokens

        // Settle USDC from Hook to PoolManager
        callbackData.currency0.settle(
            poolManager,
            address(this),
            callbackData.amount0,
            false // false because we are transferring tokens, not burning claim tokens
        );

        // Settle CIT from Hook to PoolManager
        callbackData.currency1.settle(
            poolManager,
            address(this),
            syntheticTokenAmount,
            false
        );

        callbackData.currency0.take(
            poolManager,
            address(this),
            callbackData.amount0,
            true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
        );
        callbackData.currency1.take(
            poolManager,
            address(this),
            syntheticTokenAmount,
            true
        );

        // // Calculate liquidityDelta
        // int24 tickLower = -887220;
        // int24 tickUpper = 887220;

        // uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        // uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        // uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        // // Since we are adding full range liquidity, amounts can be used directly
        // uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
        //     sqrtPriceX96,
        //     sqrtPriceLower,
        //     sqrtPriceUpper,
        //     callbackData.amount0,
        //     syntheticTokenAmount
        // );

        // // Prepare ModifyLiquidityParams
        // IPoolManager.ModifyLiquidityParams memory params = IPoolManager
        //     .ModifyLiquidityParams({
        //         tickLower: tickLower,
        //         tickUpper: tickUpper,
        //         liquidityDelta: int256(int128(liquidityDelta)),
        //         salt: bytes32(0)
        //     });

        // // Call modifyLiquidity on PoolManager
        // poolManager.modifyLiquidity(
        //     poolKey,
        //     params,
        //     "" // No extra data
        // );

        // TODO: modifyLiquidity
        return "";
    }

    // Disable direct liquidity addition via PoolManager
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert("Add liquidity via hook");
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, int128) {
        // No custom logic for swaps in this simplified version
        // TODO: swap fees to treasury
        return (this.afterSwap.selector, 0);
    }
}
