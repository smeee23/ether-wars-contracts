// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IFunctionsConsumer} from "./interfaces/link/IFunctionsConsumer.sol";

contract OracleGateway {

    address public oracle;
    address public reserve;
    address immutable public multiSig;

    /**
     * @dev Only MultiSig can call functions marked by this modifier.
     **/
    modifier onlyMultiSig(){
        require(multiSig == msg.sender, "not the owner");
        _;
    }

    /**
    * @dev Only Reserve can call functions marked by this modifier.
    **/
    modifier onlyReserve(){
        require(reserve == msg.sender, "not the owner");
        _;
    }

    constructor(address _multiSig, address _oracle){
        multiSig = _multiSig;
        oracle = _oracle;
    }

    /**
    * @param _reserve address of reserve.
    **/
    function setReserve(address _reserve) external onlyMultiSig {
        //commented out for testnet
        //require(reserve == address(0), "reserve already set");
        reserve = _reserve;
    }

    /**
    * @param _oracle address of oracle.
    **/
    function setOracle(address _oracle) external onlyMultiSig {
        //require(reserve == address(0), "reserve already set");
        oracle = _oracle;
    }

    /**
     * @dev calls FunctionsConsumer sending source code,
     * args, subId, gasLimit etc.
    * @param _index validator index for the .
    **/
    function callOracle(string memory _index) external onlyReserve {
        string memory source =
            ("const validatorIndex = args[0]\n\
            const url = 'https://flask-servicecors.rfqbhr834qlno.us-east-2.cs.amazonlightsail.com/status/'+validatorIndex.toString()\n\
            const cryptoCompareRequest = Functions.makeHttpRequest({\n\
                url: url,\n\
            })\n\
            const cryptoCompareResponse = await cryptoCompareRequest\n\
            if (cryptoCompareResponse.error) {\n\
                console.error(cryptoCompareResponse.error)\n\
                throw Error('Request failed')\n\
            }\n\
            const data = cryptoCompareResponse['data']\n\
            if (data.Response === 'Error') {\n\
                console.error(data.Message)\n\
                throw Error(`Functional error. Read message: ${data.Message}`)\n\
            }\n\
            let slashed = true;\n\
            if(!data['slashed']){\n\
                slashed = false;\n\
            }\n\
            if(data['withdrawAddress'] == '0x0'){\n\
                data['withdrawAddress'] = '0x0000000000000000000000000000000000000000'\n\
            }\n\
            let loss = data['loss'] * 1\n\
            const buffer = Buffer.alloc(1);\n\
            buffer.writeUInt8(slashed ? 1 : 0, 0)\n\
            const hexBool = buffer.toString('hex')\n\
            let hexIndex = data['index'].toString(16).padStart(64, '0')\n\
            let hexLoss = loss.toString(16).padStart(64, '0')\n\
            let result = Buffer.from(data['withdrawAddress'].slice(2)+hexBool+hexIndex+hexLoss, 'hex')\n\
            return Buffer.from(result)");
        bytes memory secrets;
        string[] memory args = new string[](1);
        args[0] = _index;
        uint64 sub = 902;
        uint32 gasLimit = 250000;
        IFunctionsConsumer(oracle).executeRequest(
            source,
            secrets,
            args,
            sub,
            gasLimit
        );
    }

}