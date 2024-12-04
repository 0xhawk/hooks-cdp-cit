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
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

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
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
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

    // Implement beforeSwap to handle swaps using the hook's liquidity
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 amountInOutPositive = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);

        // Prepare BeforeSwapDelta as per the textbook
        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
            int128(-params.amountSpecified),
            int128(params.amountSpecified)
        );

        if (params.zeroForOne) {
            // If user is selling Token 0 (USDC) and buying Token 1 (CIT)

            // Take claim tokens of USDC (currency0) from user
            key.currency0.take(
                poolManager,
                address(this),
                amountInOutPositive,
                true // Mint claim tokens
            );

            // Settle CIT (currency1) to user
            key.currency1.settle(
                poolManager,
                address(this),
                amountInOutPositive,
                true // Burn claim tokens
            );
        } else {
            // If user is selling Token 1 (CIT) and buying Token 0 (USDC)

            // Take claim tokens of CIT (currency1) from user
            key.currency1.take(
                poolManager,
                address(this),
                amountInOutPositive,
                true // Mint claim tokens
            );

            // Settle USDC (currency0) to user
            key.currency0.settle(
                poolManager,
                address(this),
                amountInOutPositive,
                true // Burn claim tokens
            );
        }
        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }
}
