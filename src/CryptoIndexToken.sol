// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "solmate/src/tokens/ERC20.sol";

contract CryptoIndexToken is ERC20 {
    address public minter;

    constructor() ERC20("Crypto Index Token", "CIT", 18) {
        minter = msg.sender;
    }

    modifier onlyMinter() {
        require(msg.sender == minter, "Not minter");
        _;
    }

    function setMinter(address _minter) external onlyMinter {
        minter = _minter;
    }

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external onlyMinter {
        _burn(from, amount);
    }
}