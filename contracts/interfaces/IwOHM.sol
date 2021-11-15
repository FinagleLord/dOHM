// SPDX-License-Identifier: WTFPL
pragma solidity >=0.8.0;

interface IwOHM {
    function wrapFromsOHM( uint256 _amount ) external returns (uint256);
    function wOHMValue( uint256 _amount ) external view returns (uint256);
}