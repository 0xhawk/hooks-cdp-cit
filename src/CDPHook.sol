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

contract CDPHook is BaseHook {
    using CurrencySettler for Currency;

    error AddLiquidityThroughHook(); // error to throw when someone tries adding liquidity directly to the PoolManager

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
        CallbackData memory callbackData = abi.decode(data, (CallbackData));
        cdpManager.mintAndDeposit(callbackData.sender, address(poolManager), callbackData.amount0);
        return "";
    }

    // Disable adding liquidity through the PM
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert AddLiquidityThroughHook();
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
