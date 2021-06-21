//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Token is ERC20("PolyGameFinance", "PolyGame"), Ownable {
    uint256 public maxSupply = 1000000000000000000000000;

    /// @notice Creates `_amount` token to `_to`. Must only be called by the owner (MasterApe).
    function mint(address _to, uint256 _amount) public onlyOwner {
        require(maxSupply > totalSupply(), "maxSupply has been reached");
        _mint(_to, _amount);
    }
}
