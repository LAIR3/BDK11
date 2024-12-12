#!/bin/bash
echo "dont run this!"
exit 1;

# # Multi Chain PP Test
#
# ## Infra Setup
#
# This is an example of a system where there are two PP chains
# attached to the rollup manager. One chain uses a gas token and the
# other does not. Between those two chains we're going to attempt a
# bunch of bridge scenarios.
#
# To run this stuff you'll want to run most of these commands from
# within the kurtosis-cdk repo root.
#
# First we're going to do a Kurtosis run to spin up both of the
# networks. The secret file here is the same as the normal file but
# with an SP1 key
kurtosis run --enclave pp --args-file .github/tests/fork12-pessimistic-secret.yml .
kurtosis run --enclave pp --args-file .github/tests/attach-second-cdk.yml .

# At this point we should be able to confirm that things look right
# for both chains. Recently, it seems like the fork id isn't initially
# detected by erigon which is causing the chain not to start up right
# away.
polycli monitor --rpc-url $(kurtosis port print pp cdk-erigon-rpc-001 rpc)
polycli monitor --rpc-url $(kurtosis port print pp cdk-erigon-rpc-002 rpc)

# In order to proceed, we'll need to grab the combined files from both
# chains. We'll specifically want the create rollup parameters file
# from the second chain because we need to know the gas token address.
kurtosis service exec pp contracts-001 "cat /opt/zkevm/combined-001.json"  | tail -n +2 | jq '.' > combined-001.json
kurtosis service exec pp contracts-002 "cat /opt/zkevm/combined-002.json"  | tail -n +2 | jq '.' > combined-002.json
kurtosis service exec pp contracts-002 "cat /opt/zkevm-contracts/deployment/v2/create_rollup_parameters.json" | tail -n +2 | jq -r '.gasTokenAddress' > gas-token-address.json

# This diagnosis isn't critical, but it's nice to confirm that we are
# using a real verifier.
cast code --rpc-url http://$(kurtosis port print pp el-1-geth-lighthouse rpc) $(cat combined-001.json | jq -r '.verifierAddress')
cast code --rpc-url http://$(kurtosis port print pp el-1-geth-lighthouse rpc) $(cat combined-002.json | jq -r '.verifierAddress')

# Check that the hash of the verifier is actually the sp1 verifier. It should be f33fc6bc90b5ea5e0272a7ab87d701bdd05ecd78b8111ca4f450eeff1e6df26a
kurtosis service exec pp contracts-001 'cat /opt/zkevm-contracts/artifacts/contracts/verifiers/SP1Verifier.sol/SP1Verifier.json' | tail -n +2 | jq -r '.deployedBytecode' | sha256sum
cast code --rpc-url http://$(kurtosis port print pp el-1-geth-lighthouse rpc) $(cat combined-001.json | jq -r '.verifierAddress') | sha256sum
cast code --rpc-url http://$(kurtosis port print pp el-1-geth-lighthouse rpc) $(cat combined-002.json | jq -r '.verifierAddress') | sha256sum

# It's also worth while probably to confirm that the vkey matches!
kurtosis service exec pp agglayer "agglayer vkey"
cast call --rpc-url http://$(kurtosis port print pp el-1-geth-lighthouse rpc) $(cat combined-001.json | jq -r '.polygonRollupManagerAddress') 'rollupTypeMap(uint32)(address,address,uint64,uint8,bool,bytes32,bytes32)' 1

# Let's make sure both rollups have the same vkey
cast call --rpc-url http://$(kurtosis port print pp el-1-geth-lighthouse rpc) $(cat combined-001.json | jq -r '.polygonRollupManagerAddress') 'rollupIDToRollupDataV2(uint32 rollupID)(address,uint64,address,uint64,bytes32,uint64,uint64,uint64,uint64,uint8,bytes32,bytes32)' 1
cast call --rpc-url http://$(kurtosis port print pp el-1-geth-lighthouse rpc) $(cat combined-001.json | jq -r '.polygonRollupManagerAddress') 'rollupIDToRollupDataV2(uint32 rollupID)(address,uint64,address,uint64,bytes32,uint64,uint64,uint64,uint64,uint8,bytes32,bytes32)' 2


# At this point, the agglayer config needs to be manually updated for
# rollup2. This will add a second entry to the agglayer config. If the
# second chain is also pessimistic, this isn't strictly necessary, but
# there's no harm in it.
kurtosis service exec pp agglayer "sed -i 's/\[proof\-signers\]/2 = \"http:\/\/cdk-erigon-rpc-002:8123\"\n\[proof-signers\]/i' /etc/zkevm/agglayer-config.toml"
kurtosis service stop pp agglayer
kurtosis service start pp agglayer

# Let's create a clean EOA for receiving bridges so that we can see
# things show up. This is a good way to make sure we don't mess things
# up by trying to exit more than we've deposited
cast wallet new
target_address=0xbecE3a31343c6019CDE0D5a4dF2AF8Df17ebcB0f
target_private_key=0x51caa196504216b1730280feb63ddd8c5ae194d13e57e58d559f1f1dc3eda7c9

# Let's setup some variables for future use
private_key="0x12d7de8621a77640c9241b2595ba78ce443d05e94090365ab3bb5e19df82c625"
eth_address=$(cast wallet address --private-key $private_key)
l1_rpc_url=http://$(kurtosis port print pp el-1-geth-lighthouse rpc)
l2_pp1_url=$(kurtosis port print pp cdk-erigon-rpc-001 rpc)
l2_pp2_url=$(kurtosis port print pp cdk-erigon-rpc-002 rpc)
bridge_address=$(cat combined-001.json | jq -r .polygonZkEVMBridgeAddress)
pol_address=$(cat combined-001.json | jq -r .polTokenAddress)
gas_token_address=$(<gas-token-address.json)
l2_pp1b_url=$(kurtosis port print pp zkevm-bridge-service-001 rpc)
l2_pp2b_url=$(kurtosis port print pp zkevm-bridge-service-002 rpc)

# Now let's make sure we have balance everywhere
cast balance --ether --rpc-url $l1_rpc_url $eth_address
cast balance --ether --rpc-url $l2_pp1_url $eth_address
cast balance --ether --rpc-url $l2_pp2_url $eth_address

# ## Initial Funding
# Let's fund the claim tx manager for both rollups. These address come
# from the chain configurations (so either input_parser or the args
# file). The claim tx manager will automatically perform claims on our
# behalf for bridge assets
cast send --legacy --value 100ether --rpc-url $l2_pp1_url --private-key $private_key 0x5f5dB0D4D58310F53713eF4Df80ba6717868A9f8
cast send --legacy --value 100ether --rpc-url $l2_pp2_url --private-key $private_key 0x93F63c24735f45Cd0266E87353071B64dd86bc05

# We should also fund the target address on L1 so that we can use this
# key for L1 bridge transfers
cast send --value 100ether --rpc-url $l1_rpc_url --private-key $private_key $target_address

# Let's mint some POL token for testing purpsoes
cast send \
     --rpc-url $l1_rpc_url \
     --private-key $private_key \
     $pol_address \
     'mint(address,uint256)' \
     $eth_address 10000000000000000000000

# We also need to approve the token so that the bridge can spend it.
cast send \
     --rpc-url $l1_rpc_url \
     --private-key $private_key \
     $pol_address \
     'approve(address,uint256)' \
     $bridge_address 10000000000000000000000

# Let's also mint some of the gas token for our second network
cast send \
     --rpc-url $l1_rpc_url \
     --private-key $private_key \
     $gas_token_address \
     'mint(address,uint256)' \
     $eth_address 10000000000000000000000
cast send \
     --rpc-url $l1_rpc_url \
     --private-key $private_key \
     $gas_token_address \
     'approve(address,uint256)' \
     $bridge_address 10000000000000000000000

# We're also going to mint POL and Gas Token from the target account
# for additional test scenarios. The logic here is that we don't want
# to send Ether to the target address on L2 because we might risk
# withdrawing more than we deposit
cast send --rpc-url $l1_rpc_url --private-key $target_private_key $pol_address 'mint(address,uint256)' $target_address 10000000000000000000000
cast send --rpc-url $l1_rpc_url --private-key $target_private_key $pol_address 'approve(address,uint256)' $bridge_address 10000000000000000000000

cast send --rpc-url $l1_rpc_url --private-key $target_private_key $gas_token_address 'mint(address,uint256)' $target_address 10000000000000000000000
cast send --rpc-url $l1_rpc_url --private-key $target_private_key $gas_token_address 'approve(address,uint256)' $bridge_address 10000000000000000000000

# We're going to do a little matrix of L1 to L2 bridges here. The idea
# is to mix bridges across a few scenarios
# - Native vs ERC20
# - Bridge Message vs Bridge Asset
# - GER Updating
dry_run=false
for token_addr in $(cast az) $pol_address $gas_token_address ; do
    for destination_network in 1 2 ; do
        for ger_update in "false" "true" ; do
            permit_data="0x"
            value="1000000000000000000"
            if [[ $token_addr == $(cast az) ]]; then
                permit_data="0x$(cat /dev/random | xxd -p | tr -d "\n" | head -c $((RANDOM & ~1)))"
            fi
            polycli ulxly bridge asset \
                    --private-key $private_key \
                    --value $value \
                    --bridge-address $bridge_address \
                    --destination-network $destination_network \
                    --destination-address $target_address \
                    --call-data $permit_data \
                    --rpc-url $l1_rpc_url \
                    --token-address $token_addr \
                    --force-update-root=$ger_update \
                    --dry-run=$dry_run
            polycli ulxly bridge message \
                    --private-key $private_key \
                    --value $value \
                    --bridge-address $bridge_address \
                    --destination-network $destination_network \
                    --destination-address $target_address \
                    --call-data $permit_data \
                    --rpc-url $l1_rpc_url \
                    --force-update-root=$ger_update \
                    --dry-run=$dry_run
        done
    done
done

# At this point, we should be able to see our bridges in the bridge
# service for both chains. Recently, with this setup there has been an
# issue with network id detection in the bridge service
curl -s $l2_pp1b_url/bridges/$target_address | jq '.'
curl -s $l2_pp2b_url/bridges/$target_address | jq '.'

# Some of the bridges will be claimed already, but some will need to
# be claimed manually. Most of the ones that need to be claimed
# manually should be `leaf_type` of `1` i.e. a message rather than an
# asset.
curl -s $l2_pp1b_url/bridges/$target_address | jq '.deposits[] | select(.ready_for_claim) | select(.claim_tx_hash == "")'
curl -s $l2_pp2b_url/bridges/$target_address | jq '.deposits[] | select(.ready_for_claim) | select(.claim_tx_hash == "")'

# We should be able to take these commands and then try to claim each
# of the deposits.
curl -s $l2_pp1b_url/bridges/$target_address | jq -c '.deposits[] | select(.ready_for_claim) | select(.claim_tx_hash == "")' | while read deposit ; do
    polycli ulxly claim message \
            --bridge-address $bridge_address \
            --bridge-service-url $l2_pp1b_url \
            --rpc-url $l2_pp1_url \
            --deposit-count $(echo $deposit | jq -r '.deposit_cnt') \
            --deposit-network $(echo $deposit | jq -r '.orig_net') \
            --destination-address $(echo $deposit | jq -r '.dest_addr') \
            --private-key $private_key
done

curl -s $l2_pp2b_url/bridges/$target_address | jq -c '.deposits[] | select(.ready_for_claim) | select(.claim_tx_hash == "")' | while read deposit ; do
    polycli ulxly claim message \
            --bridge-address $bridge_address \
            --bridge-service-url $l2_pp2b_url \
            --rpc-url $l2_pp2_url \
            --deposit-count $(echo $deposit | jq -r '.deposit_cnt') \
            --deposit-network $(echo $deposit | jq -r '.orig_net') \
            --destination-address $(echo $deposit | jq -r '.dest_addr') \
            --private-key $private_key
done

# Hopefully at this point everything has been claimed on L2. These
# calls should return empty.
curl -s $l2_pp1b_url/bridges/$target_address | jq '.deposits[] | select(.ready_for_claim) | select(.claim_tx_hash == "")'
curl -s $l2_pp2b_url/bridges/$target_address | jq '.deposits[] | select(.ready_for_claim) | select(.claim_tx_hash == "")'

# Let's see if our balances have grown (both should be non-zero)
cast balance --ether --rpc-url $l2_pp1_url $target_address
cast balance --ether --rpc-url $l2_pp2_url $target_address

# Let's check our L2 Pol token balance (both should be non-zero)
token_hash=$(cast keccak $(cast abi-encode --packed 'f(uint32,address)' 0 $pol_address))
l2_pol_address=$(cast call --rpc-url $l2_pp1_url  $bridge_address 'tokenInfoToWrappedToken(bytes32)(address)' $token_hash)
cast call --rpc-url $l2_pp1_url $l2_pol_address 'balanceOf(address)(uint256)' $target_address
cast call --rpc-url $l2_pp2_url $l2_pol_address 'balanceOf(address)(uint256)' $target_address

# We should also check our gas token balance on both networks. The
# first network should have a balance because it's treated as ordinary
# token. The other network should have nothing because the bridge
# would have been received as a native token.
token_hash=$(cast keccak $(cast abi-encode --packed 'f(uint32,address)' 0 $gas_token_address))
l2_gas_address=$(cast call --rpc-url $l2_pp1_url  $bridge_address 'tokenInfoToWrappedToken(bytes32)(address)' $token_hash)
cast call --rpc-url $l2_pp1_url $l2_gas_address 'balanceOf(address)(uint256)' $target_address
cast call --rpc-url $l2_pp2_url $l2_gas_address 'balanceOf(address)(uint256)' $target_address

# Similarly, we should confirm that on the second network we have some
# wrapped ETH.
pp2_weth_address=$(cast call --rpc-url $l2_pp2_url $bridge_address 'WETHToken()(address)')
cast call --rpc-url $l2_pp2_url  $pp2_weth_address 'balanceOf(address)(uint256)' $target_address


# ## Test Bridges
#
# At this point we have enough funds on L2s to start doing some bridge
# exits, i.e moving funds out of one rollup into another. It's
# important for these tests to use the `target_private_key` to ensure
# we don't accidentally try to bridge funds out of L2 that weren't
# bridged there initially. This is a completely valid test case, but
# it might cause an issue with the agglayer that blocks our tests.
#
# Let's try a native bridge from PP1 back to layer one
polycli ulxly bridge asset \
        --private-key $target_private_key \
        --value $(date +%s) \
        --bridge-address $bridge_address \
        --destination-network 0 \
        --destination-address $target_address \
        --force-update-root=true \
        --rpc-url $l2_pp1_url

# Now let's try a native bridge from PP1 back to PP2
polycli ulxly bridge asset \
        --private-key $target_private_key \
        --value $(date +%s) \
        --bridge-address $bridge_address \
        --destination-network 2 \
        --destination-address $target_address \
        --force-update-root=true \
        --rpc-url $l2_pp1_url

# Neither of these transactions will be claimed automatically. So
# let's claim them and make sure that works fine.
curl -s $l2_pp1b_url/bridges/$target_address | jq '.deposits[] | select(.ready_for_claim) | select(.claim_tx_hash == "")'
deposit_cnt=0
polycli ulxly claim asset \
        --bridge-address $bridge_address \
        --bridge-service-url $l2_pp1b_url \
        --rpc-url $l1_rpc_url \
        --deposit-count $deposit_cnt \
        --deposit-network 1 \
        --destination-address $target_address \
        --private-key $private_key

# The details of this particular claim are probably a little weird
# looking because it's an L2 to L2 claim. The deposit network is 1
# because that's where the bridge originated. We're using the deposit
# network's bridge service. And then we're making the claim against
# the network 2 RPC. The tricky thing is, the claim tx hash will never
# show up in the bridge service for this particular tx now.
deposit_cnt=1
polycli ulxly claim asset \
        --bridge-address $bridge_address \
        --bridge-service-url $l2_pp1b_url \
        --rpc-url $l2_pp2_url \
        --deposit-count $deposit_cnt \
        --deposit-network 1 \
        --destination-address $target_address \
        --private-key $private_key


# Let's try the same test now, but for PP2. Remember, PP2 is a gas
# token network, so when we bridge to other networks it should be
# turned into an ERC20 of some kind.
polycli ulxly bridge asset \
        --private-key $target_private_key \
        --value $(date +%s) \
        --bridge-address $bridge_address \
        --destination-network 0 \
        --destination-address $target_address \
        --force-update-root=true \
        --rpc-url $l2_pp2_url

polycli ulxly bridge asset \
        --private-key $target_private_key \
        --value $(date +%s) \
        --bridge-address $bridge_address \
        --destination-network 1 \
        --destination-address $target_address \
        --force-update-root=true \
        --rpc-url $l2_pp2_url

polycli ulxly bridge weth \
        --private-key $target_private_key \
        --value $(date +%s) \
        --bridge-address $bridge_address \
        --destination-network 1 \
        --destination-address $target_address \
        --force-update-root=true \
        --token-address $pp2_weth_address \
        --rpc-url $l2_pp2_url

# Now we should try to claim these transactions again on Layer one and PP1
curl -s $l2_pp2b_url/bridges/$target_address | jq '.deposits[] | select(.ready_for_claim) | select(.claim_tx_hash == "")'

deposit_cnt=0
polycli ulxly claim asset \
        --bridge-address $bridge_address \
        --bridge-service-url $l2_pp2b_url \
        --rpc-url $l1_rpc_url \
        --deposit-count $deposit_cnt \
        --deposit-network 2 \
        --destination-address $target_address \
        --private-key $private_key

deposit_cnt=1
polycli ulxly claim asset \
        --bridge-address $bridge_address \
        --bridge-service-url $l2_pp2b_url \
        --rpc-url $l2_pp1_url \
        --deposit-count $deposit_cnt \
        --deposit-network 2 \
        --destination-address $target_address \
        --private-key $private_key

deposit_cnt=2
polycli ulxly claim message \
        --bridge-address $bridge_address \
        --bridge-service-url $l2_pp2b_url \
        --rpc-url $l2_pp1_url \
        --deposit-count $deposit_cnt \
        --deposit-network 2 \
        --destination-address $target_address \
        --private-key $private_key

cast call --rpc-url $l1_rpc_url $bridge_address 'depositCount() external view returns (uint256)'

# ## Pict Based Test Scenarios
#
# The goal here is to have some methods for creating more robust
# testing combinations. In theory, we can probably brute force test
# every combination of parameters, but as the number of parameters
# grows, this might become too difficult. I'm using a command like
# this to generate the test cases.
pict lxly.pict /f:json | jq -c '.[] | from_entries' | jq -s > test-scenarios.json

# For the sake of simplicity, I'm going to use the deterministic
# deployer so that I have the same ERC20 address on each chain. Here
# I'm adding some funds to the deterministict deployer address.
cast send --legacy --value 0.1ether --rpc-url $l1_rpc_url --private-key $private_key 0x3fab184622dc19b6109349b94811493bf2a45362
cast send --legacy --value 0.1ether --rpc-url $l2_pp1_url --private-key $private_key 0x3fab184622dc19b6109349b94811493bf2a45362
cast send --legacy --value 0.1ether --rpc-url $l2_pp2_url --private-key $private_key 0x3fab184622dc19b6109349b94811493bf2a45362

# The tx data and address are standard for the deterministict deployer
deterministic_deployer_tx=0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222
deterministic_deployer_addr=0x4e59b44847b379578588920ca78fbf26c0b4956c

cast publish --rpc-url $l1_rpc_url $deterministic_deployer_tx
cast publish --rpc-url $l2_pp1_url $deterministic_deployer_tx
cast publish --rpc-url $l2_pp2_url $deterministic_deployer_tx


salt=0x6a6f686e2068696c6c696172642077617320686572650a000000000000000000
erc_20_bytecode=60806040526040516200143a3803806200143a833981016040819052620000269162000201565b8383600362000036838262000322565b50600462000045828262000322565b5050506200005a82826200007160201b60201c565b505081516020909201919091206006555062000416565b6001600160a01b038216620000cc5760405162461bcd60e51b815260206004820152601f60248201527f45524332303a206d696e7420746f20746865207a65726f206164647265737300604482015260640160405180910390fd5b8060026000828254620000e09190620003ee565b90915550506001600160a01b038216600081815260208181526040808320805486019055518481527fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef910160405180910390a35050565b505050565b634e487b7160e01b600052604160045260246000fd5b600082601f8301126200016457600080fd5b81516001600160401b03808211156200018157620001816200013c565b604051601f8301601f19908116603f01168101908282118183101715620001ac57620001ac6200013c565b81604052838152602092508683858801011115620001c957600080fd5b600091505b83821015620001ed5785820183015181830184015290820190620001ce565b600093810190920192909252949350505050565b600080600080608085870312156200021857600080fd5b84516001600160401b03808211156200023057600080fd5b6200023e8883890162000152565b955060208701519150808211156200025557600080fd5b50620002648782880162000152565b604087015190945090506001600160a01b03811681146200028457600080fd5b6060959095015193969295505050565b600181811c90821680620002a957607f821691505b602082108103620002ca57634e487b7160e01b600052602260045260246000fd5b50919050565b601f8211156200013757600081815260208120601f850160051c81016020861015620002f95750805b601f850160051c820191505b818110156200031a5782815560010162000305565b505050505050565b81516001600160401b038111156200033e576200033e6200013c565b62000356816200034f845462000294565b84620002d0565b602080601f8311600181146200038e5760008415620003755750858301515b600019600386901b1c1916600185901b1785556200031a565b600085815260208120601f198616915b82811015620003bf578886015182559484019460019091019084016200039e565b5085821015620003de5787850151600019600388901b60f8161c191681555b5050505050600190811b01905550565b808201808211156200041057634e487b7160e01b600052601160045260246000fd5b92915050565b61101480620004266000396000f3fe608060405234801561001057600080fd5b506004361061014d5760003560e01c806340c10f19116100c35780639e4e73181161007c5780639e4e73181461033c578063a457c2d714610363578063a9059cbb14610376578063c473af3314610389578063d505accf146103b0578063dd62ed3e146103c357600080fd5b806340c10f19146102b257806342966c68146102c557806356189cb4146102d857806370a08231146102eb5780637ecebe001461031457806395d89b411461033457600080fd5b806323b872dd1161011557806323b872dd146101c357806330adf81f146101d6578063313ce567146101fd5780633408e4701461020c5780633644e51514610212578063395093511461029f57600080fd5b806304622c2e1461015257806306fdde031461016e578063095ea7b31461018357806318160ddd146101a6578063222f5be0146101ae575b600080fd5b61015b60065481565b6040519081526020015b60405180910390f35b6101766103d6565b6040516101659190610db1565b610196610191366004610e1b565b610468565b6040519015158152602001610165565b60025461015b565b6101c16101bc366004610e45565b610482565b005b6101966101d1366004610e45565b610492565b61015b7f6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c981565b60405160128152602001610165565b4661015b565b61015b6006546000907f8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f907fc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc646604080516020810195909552840192909252606083015260808201523060a082015260c00160405160208183030381529060405280519060200120905090565b6101966102ad366004610e1b565b6104b6565b6101c16102c0366004610e1b565b6104d8565b6101c16102d3366004610e81565b6104e6565b6101c16102e6366004610e45565b6104f3565b61015b6102f9366004610e9a565b6001600160a01b031660009081526020819052604090205490565b61015b610322366004610e9a565b60056020526000908152604090205481565b6101766104fe565b61015b7fc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc681565b610196610371366004610e1b565b61050d565b610196610384366004610e1b565b61058d565b61015b7f8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f81565b6101c16103be366004610ebc565b61059b565b61015b6103d1366004610f2f565b6106ae565b6060600380546103e590610f62565b80601f016020809104026020016040519081016040528092919081815260200182805461041190610f62565b801561045e5780601f106104335761010080835404028352916020019161045e565b820191906000526020600020905b81548152906001019060200180831161044157829003601f168201915b5050505050905090565b6000336104768185856106d9565b60019150505b92915050565b61048d8383836107fd565b505050565b6000336104a08582856109a3565b6104ab8585856107fd565b506001949350505050565b6000336104768185856104c983836106ae565b6104d39190610fb2565b6106d9565b6104e28282610a17565b5050565b6104f03382610ad6565b50565b61048d8383836106d9565b6060600480546103e590610f62565b6000338161051b82866106ae565b9050838110156105805760405162461bcd60e51b815260206004820152602560248201527f45524332303a2064656372656173656420616c6c6f77616e63652062656c6f77604482015264207a65726f60d81b60648201526084015b60405180910390fd5b6104ab82868684036106d9565b6000336104768185856107fd565b428410156105eb5760405162461bcd60e51b815260206004820152601960248201527f48455a3a3a7065726d69743a20415554485f45585049524544000000000000006044820152606401610577565b6001600160a01b038716600090815260056020526040812080547f6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9918a918a918a91908661063883610fc5565b909155506040805160208101969096526001600160a01b0394851690860152929091166060840152608083015260a082015260c0810186905260e0016040516020818303038152906040528051906020012090506106998882868686610c08565b6106a48888886106d9565b5050505050505050565b6001600160a01b03918216600090815260016020908152604080832093909416825291909152205490565b6001600160a01b03831661073b5760405162461bcd60e51b8152602060048201526024808201527f45524332303a20617070726f76652066726f6d20746865207a65726f206164646044820152637265737360e01b6064820152608401610577565b6001600160a01b03821661079c5760405162461bcd60e51b815260206004820152602260248201527f45524332303a20617070726f766520746f20746865207a65726f206164647265604482015261737360f01b6064820152608401610577565b6001600160a01b0383811660008181526001602090815260408083209487168084529482529182902085905590518481527f8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925910160405180910390a3505050565b6001600160a01b0383166108615760405162461bcd60e51b815260206004820152602560248201527f45524332303a207472616e736665722066726f6d20746865207a65726f206164604482015264647265737360d81b6064820152608401610577565b6001600160a01b0382166108c35760405162461bcd60e51b815260206004820152602360248201527f45524332303a207472616e7366657220746f20746865207a65726f206164647260448201526265737360e81b6064820152608401610577565b6001600160a01b0383166000908152602081905260409020548181101561093b5760405162461bcd60e51b815260206004820152602660248201527f45524332303a207472616e7366657220616d6f756e7420657863656564732062604482015265616c616e636560d01b6064820152608401610577565b6001600160a01b03848116600081815260208181526040808320878703905593871680835291849020805487019055925185815290927fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef910160405180910390a35b50505050565b60006109af84846106ae565b9050600019811461099d5781811015610a0a5760405162461bcd60e51b815260206004820152601d60248201527f45524332303a20696e73756666696369656e7420616c6c6f77616e63650000006044820152606401610577565b61099d84848484036106d9565b6001600160a01b038216610a6d5760405162461bcd60e51b815260206004820152601f60248201527f45524332303a206d696e7420746f20746865207a65726f2061646472657373006044820152606401610577565b8060026000828254610a7f9190610fb2565b90915550506001600160a01b038216600081815260208181526040808320805486019055518481527fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef910160405180910390a35050565b6001600160a01b038216610b365760405162461bcd60e51b815260206004820152602160248201527f45524332303a206275726e2066726f6d20746865207a65726f206164647265736044820152607360f81b6064820152608401610577565b6001600160a01b03821660009081526020819052604090205481811015610baa5760405162461bcd60e51b815260206004820152602260248201527f45524332303a206275726e20616d6f756e7420657863656564732062616c616e604482015261636560f01b6064820152608401610577565b6001600160a01b0383166000818152602081815260408083208686039055600280548790039055518581529192917fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef910160405180910390a3505050565b600654604080517f8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f602080830191909152818301939093527fc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc660608201524660808201523060a0808301919091528251808303909101815260c082019092528151919092012061190160f01b60e083015260e282018190526101028201869052906000906101220160408051601f198184030181528282528051602091820120600080855291840180845281905260ff89169284019290925260608301879052608083018690529092509060019060a0016020604051602081039080840390855afa158015610d1b573d6000803e3d6000fd5b5050604051601f1901519150506001600160a01b03811615801590610d515750876001600160a01b0316816001600160a01b0316145b6106a45760405162461bcd60e51b815260206004820152602b60248201527f48455a3a3a5f76616c69646174655369676e6564446174613a20494e56414c4960448201526a445f5349474e415455524560a81b6064820152608401610577565b600060208083528351808285015260005b81811015610dde57858101830151858201604001528201610dc2565b506000604082860101526040601f19601f8301168501019250505092915050565b80356001600160a01b0381168114610e1657600080fd5b919050565b60008060408385031215610e2e57600080fd5b610e3783610dff565b946020939093013593505050565b600080600060608486031215610e5a57600080fd5b610e6384610dff565b9250610e7160208501610dff565b9150604084013590509250925092565b600060208284031215610e9357600080fd5b5035919050565b600060208284031215610eac57600080fd5b610eb582610dff565b9392505050565b600080600080600080600060e0888a031215610ed757600080fd5b610ee088610dff565b9650610eee60208901610dff565b95506040880135945060608801359350608088013560ff81168114610f1257600080fd5b9699959850939692959460a0840135945060c09093013592915050565b60008060408385031215610f4257600080fd5b610f4b83610dff565b9150610f5960208401610dff565b90509250929050565b600181811c90821680610f7657607f821691505b602082108103610f9657634e487b7160e01b600052602260045260246000fd5b50919050565b634e487b7160e01b600052601160045260246000fd5b8082018082111561047c5761047c610f9c565b600060018201610fd757610fd7610f9c565b506001019056fea26469706673582212207bede9966bc8e8634cc0c3dc076626579b27dff7bbcac0b645c87d4cf1812b9864736f6c63430008140033
constructor_args=$(cast abi-encode 'f(string,string,address,uint256)' 'Bridge Test' 'BT' "$target_address" 100000000000000000000 | sed 's/0x//')

cast send --legacy --rpc-url $l1_rpc_url --private-key $private_key $deterministic_deployer_addr $salt$erc_20_bytecode$constructor_args
cast send --legacy --rpc-url $l2_pp1_url --private-key $private_key $deterministic_deployer_addr $salt$erc_20_bytecode$constructor_args
cast send --legacy --rpc-url $l2_pp2_url --private-key $private_key $deterministic_deployer_addr $salt$erc_20_bytecode$constructor_args

test_erc20_addr=$(cast create2 --salt $salt --init-code $erc_20_bytecode$constructor_args)

cast send --legacy --rpc-url $l1_rpc_url --private-key $target_private_key $test_erc20_addr 'approve(address,uint256)' $bridge_address 100000000000000000000
cast send --legacy --rpc-url $l2_pp1_url --private-key $target_private_key $test_erc20_addr 'approve(address,uint256)' $bridge_address 100000000000000000000
cast send --legacy --rpc-url $l2_pp2_url --private-key $target_private_key $test_erc20_addr 'approve(address,uint256)' $bridge_address 100000000000000000000

# docker run -v $PWD/src:/contracts ethereum/solc:0.7.6 --bin /contracts/tokens/ERC20Buggy.sol
erc20_buggy_bytecode=608060405234801561001057600080fd5b506040516109013803806109018339818101604052606081101561003357600080fd5b810190808051604051939291908464010000000082111561005357600080fd5b90830190602082018581111561006857600080fd5b825164010000000081118282018810171561008257600080fd5b82525081516020918201929091019080838360005b838110156100af578181015183820152602001610097565b50505050905090810190601f1680156100dc5780820380516001836020036101000a031916815260200191505b50604052602001805160405193929190846401000000008211156100ff57600080fd5b90830190602082018581111561011457600080fd5b825164010000000081118282018810171561012e57600080fd5b82525081516020918201929091019080838360005b8381101561015b578181015183820152602001610143565b50505050905090810190601f1680156101885780820380516001836020036101000a031916815260200191505b5060405260209081015185519093506101a792506003918601906101d8565b5081516101bb9060049060208501906101d8565b506005805460ff191660ff92909216919091179055506102799050565b828054600181600116156101000203166002900490600052602060002090601f01602090048101928261020e5760008555610254565b82601f1061022757805160ff1916838001178555610254565b82800160010185558215610254579182015b82811115610254578251825591602001919060010190610239565b50610260929150610264565b5090565b5b808211156102605760008155600101610265565b610679806102886000396000f3fe608060405234801561001057600080fd5b50600436106100b45760003560e01c806370a082311161007157806370a082311461021257806395d89b41146102385780639dc29fac14610240578063a9059cbb1461026c578063b46310f614610298578063dd62ed3e146102c4576100b4565b806306fdde03146100b9578063095ea7b31461013657806318160ddd1461017657806323b872dd14610190578063313ce567146101c657806340c10f19146101e4575b600080fd5b6100c16102f2565b6040805160208082528351818301528351919283929083019185019080838360005b838110156100fb5781810151838201526020016100e3565b50505050905090810190601f1680156101285780820380516001836020036101000a031916815260200191505b509250505060405180910390f35b6101626004803603604081101561014c57600080fd5b506001600160a01b038135169060200135610380565b604080519115158252519081900360200190f35b61017e6103e6565b60408051918252519081900360200190f35b610162600480360360608110156101a657600080fd5b506001600160a01b038135811691602081013590911690604001356103ec565b6101ce610466565b6040805160ff9092168252519081900360200190f35b610210600480360360408110156101fa57600080fd5b506001600160a01b03813516906020013561046f565b005b61017e6004803603602081101561022857600080fd5b50356001600160a01b031661047d565b6100c161048f565b6102106004803603604081101561025657600080fd5b506001600160a01b0381351690602001356104ea565b6101626004803603604081101561028257600080fd5b506001600160a01b0381351690602001356104f4565b610210600480360360408110156102ae57600080fd5b506001600160a01b03813516906020013561054f565b61017e600480360360408110156102da57600080fd5b506001600160a01b038135811691602001351661056b565b6003805460408051602060026001851615610100026000190190941693909304601f810184900484028201840190925281815292918301828280156103785780601f1061034d57610100808354040283529160200191610378565b820191906000526020600020905b81548152906001019060200180831161035b57829003601f168201915b505050505081565b3360008181526002602090815260408083206001600160a01b038716808552908352818420869055815186815291519394909390927f8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925928290030190a350600192915050565b60005481565b6001600160a01b0380841660008181526002602090815260408083203384528252808320805487900390558383526001825280832080548790039055938616808352848320805487019055845186815294519294909392600080516020610624833981519152929181900390910190a35060019392505050565b60055460ff1681565b6104798282610588565b5050565b60016020526000908152604090205481565b6004805460408051602060026001851615610100026000190190941693909304601f810184900484028201840190925281815292918301828280156103785780601f1061034d57610100808354040283529160200191610378565b61047982826105d3565b336000818152600160209081526040808320805486900390556001600160a01b03861680845281842080548701905581518681529151939490939092600080516020610624833981519152928290030190a350600192915050565b6001600160a01b03909116600090815260016020526040902055565b600260209081526000928352604080842090915290825290205481565b6001600160a01b038216600081815260016020908152604080832080548601905582548501835580518581529051600080516020610624833981519152929181900390910190a35050565b6001600160a01b0382166000818152600160209081526040808320805486900390558254859003835580518581529051929392600080516020610624833981519152929181900390910190a3505056feddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa2646970667358221220364a383ccce0e270376267b8631412d1b7ddb1883c5379556b58cbefc1ca504564736f6c63430007060033
constructor_args=$(cast abi-encode 'f(string,string,uint8)' 'Buggy ERC20' 'BUG' "18" | sed 's/0x//')

cast send --legacy --rpc-url $l1_rpc_url --private-key $private_key $deterministic_deployer_addr $salt$erc20_buggy_bytecode$constructor_args
cast send --legacy --rpc-url $l2_pp1_url --private-key $private_key $deterministic_deployer_addr $salt$erc20_buggy_bytecode$constructor_args
cast send --legacy --rpc-url $l2_pp2_url --private-key $private_key $deterministic_deployer_addr $salt$erc20_buggy_bytecode$constructor_args

test_erc20_buggy_addr=$(cast create2 --salt $salt --init-code $erc20_buggy_bytecode$constructor_args)

cast send --legacy --rpc-url $l1_rpc_url --private-key $target_private_key $test_erc20_buggy_addr 'mint(address,uint256)' $target_address $(cast max-uint)
cast send --legacy --rpc-url $l2_pp1_url --private-key $target_private_key $test_erc20_buggy_addr 'mint(address,uint256)' $target_address $(cast max-uint)
cast send --legacy --rpc-url $l2_pp2_url --private-key $target_private_key $test_erc20_buggy_addr 'mint(address,uint256)' $target_address $(cast max-uint)

cast send --legacy --rpc-url $l1_rpc_url --private-key $target_private_key $test_erc20_buggy_addr 'approve(address,uint256)' $bridge_address $(cast max-uint)
cast send --legacy --rpc-url $l2_pp1_url --private-key $target_private_key $test_erc20_buggy_addr 'approve(address,uint256)' $bridge_address $(cast max-uint)
cast send --legacy --rpc-url $l2_pp2_url --private-key $target_private_key $test_erc20_buggy_addr 'approve(address,uint256)' $bridge_address $(cast max-uint)

# One of the test cases that I've left out for now is a permit
# call. It'll take some work to get the signed permit data in place,
# but it seems doable.
#
# - https://eips.ethereum.org/EIPS/eip-2612
# - https://eips.ethereum.org/EIPS/eip-712
#
# permit_sig=$(cast wallet sign --private-key $target_private_key 0x$(< /dev/urandom xxd -p | tr -d "\n" | head -c 40))
# permit_sig_r=${permit_sig:2:64}
# permit_sig_s=${permit_sig:66:64}
# permit_sig_v=${permit_sig:130:2}

# The test cases are committed for convenience, we'll use that to
# dynamically to some testing
cat test-scenarios.json | jq -c '.[]' | while read scenario ; do
    testBridgeType=$(echo $scenario | jq -r '.BridgeType')
    testDepositChain=$(echo $scenario | jq -r '.DepositChain')
    testDestinationChain=$(echo $scenario | jq -r '.DestinationChain')
    testDestinationAddress=$(echo $scenario | jq -r '.DestinationAddress')
    testToken=$(echo $scenario | jq -r '.Token')
    testMetaData=$(echo $scenario | jq -r '.MetaData')
    testForceUpdate=$(echo $scenario | jq -r '.ForceUpdate')
    testAmount=$(echo $scenario | jq -r '.Amount')

    testCommand="polycli ulxly bridge"

    if [[ $testBridgeType == "Asset" ]]; then
        testCommand="$testCommand asset"
    elif [[ $testBridgeType == "Message" ]]; then
        testCommand="$testCommand message"
    else
        testCommand="$testCommand weth"
    fi

    if [[ $testDepositChain == "L1" ]]; then
        testCommand="$testCommand --rpc-url $l1_rpc_url"
    elif [[ $testDepositChain == "PP1" ]]; then
        testCommand="$testCommand --rpc-url $l2_pp1_url"
    else
        testCommand="$testCommand --rpc-url $l2_pp2_url"
    fi

    if [[ $testDestinationChain == "L1" ]]; then
        testCommand="$testCommand --destination-network 0"
    elif [[ $testDestinationChain == "PP1" ]]; then
        testCommand="$testCommand --destination-network 1"
    else
        testCommand="$testCommand --destination-network 2"
    fi

    if [[ $testDestinationAddress == "Contract" ]]; then
        testCommand="$testCommand --destination-address $bridge_address"
    elif [[ $testDestinationAddress == "Precompile" ]]; then
        testCommand="$testCommand --destination-address 0x0000000000000000000000000000000000000004"
    else
        testCommand="$testCommand --destination-address $target_address"
    fi

    if [[ $testToken == "POL" ]]; then
        testCommand="$testCommand --token-address $pol_address"
    elif [[ $testToken == "LocalERC20" ]]; then
        testCommand="$testCommand --token-address $test_erc20_addr"
    elif [[ $testToken == "WETH" ]]; then
        testCommand="$testCommand --token-address $pp2_weth_address"
    elif [[ $testToken == "Invalid" ]]; then
        testCommand="$testCommand --token-address $(< /dev/urandom xxd -p | tr -d "\n" | head -c 40)"
    else
        testCommand="$testCommand --token-address 0x0000000000000000000000000000000000000000"
    fi

    if [[ $testMetaData == "Random" ]]; then
        testCommand="$testCommand --call-data $(date +%s | xxd -p)"
    else
        testCommand="$testCommand --call-data 0x"
    fi

    if [[ $testForceUpdate == "True" ]]; then
        testCommand="$testCommand --force-update-root=true"
    else
        testCommand="$testCommand --force-update-root=false"
    fi

    if [[ $testAmount == "0" ]]; then
        testCommand="$testCommand --value 0"
    elif [[ $testAmount == "1" ]]; then
        testCommand="$testCommand --value 1"
    else
        testCommand="$testCommand --value $(date +%s)"
    fi

    testCommand="$testCommand --bridge-address $bridge_address"
    testCommand="$testCommand --private-key $target_private_key"

    echo $scenario | jq -c '.'
    echo $testCommand
    $testCommand
done


curl -s $l2_pp2b_url/bridges/$target_address | jq -c '.deposits[] | select(.network_id == 2) | select(.dest_net == 1)' | while read deposit ; do
    echo $deposit | jq -c '.'
    leaf_type=$(echo $deposit | jq -r '.leaf_type')
    if [[ $leaf_type == "0" ]]; then
        polycli ulxly claim asset \
                --bridge-address $bridge_address \
                --bridge-service-url $l2_pp2b_url \
                --rpc-url $l2_pp1_url \
                --deposit-count $(echo $deposit | jq -r '.deposit_cnt') \
                --deposit-network 2 \
                --destination-address $(echo $deposit | jq -r '.dest_addr') \
                --private-key $private_key

    else
        polycli ulxly claim message \
                --bridge-address $bridge_address \
                --bridge-service-url $l2_pp2b_url \
                --rpc-url $l2_pp1_url \
                --deposit-count $(echo $deposit | jq -r '.deposit_cnt') \
                --deposit-network 2 \
                --destination-address $(echo $deposit | jq -r '.dest_addr') \
                --private-key $private_key
    fi
done
curl -s $l2_pp1b_url/bridges/$target_address | jq -c '.deposits[] | select(.network_id == 1) | select(.dest_net == 2)' | while read deposit ; do
    echo $deposit | jq -c '.'
    leaf_type=$(echo $deposit | jq -r '.leaf_type')
    if [[ $leaf_type == "0" ]]; then
        polycli ulxly claim asset \
                --bridge-address $bridge_address \
                --bridge-service-url $l2_pp1b_url \
                --rpc-url $l2_pp2_url \
                --deposit-count $(echo $deposit | jq -r '.deposit_cnt') \
                --deposit-network 1 \
                --destination-address $(echo $deposit | jq -r '.dest_addr') \
                --private-key $private_key

    else
        polycli ulxly claim message \
                --bridge-address $bridge_address \
                --bridge-service-url $l2_pp1b_url \
                --rpc-url $l2_pp2_url \
                --deposit-count $(echo $deposit | jq -r '.deposit_cnt') \
                --deposit-network 1 \
                --destination-address $(echo $deposit | jq -r '.dest_addr') \
                --private-key $private_key
    fi
done

# ## Buggy ERC 20
#
# These are some simple tests to try bridging more than the uint max
# limit to understand how the balance tree might be impacted. We're
# going to run thie snippt below a few times which does the following.
#
# 1. Bridge the max amount possible from the target address. This
# assumes we've already minted some
# 2. Mint the max amount again for the target address.
# 3. Zero out the balance of the bridge
#
# Repeat that a few times just to make sure everything is okay. The
# commands below are for doing tests from PP1 to PP2

polycli ulxly bridge asset \
        --private-key $target_private_key \
        --value 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe \
        --bridge-address $bridge_address \
        --destination-network 2 \
        --destination-address $target_address \
        --rpc-url $l2_pp1_url \
        --token-address $test_erc20_buggy_addr \
        --force-update-root=true

cast send --legacy --rpc-url $l2_pp1_url --private-key $target_private_key $test_erc20_buggy_addr 'mint(address,uint256)' $target_address $(cast max-uint)
cast send --legacy --rpc-url $l2_pp1_url --private-key $target_private_key $test_erc20_buggy_addr 'setBalanceOf(address,uint256)' $bridge_address 0


# These commands do the same thing more or less but from PP2 to PP1
polycli ulxly bridge asset \
        --private-key $target_private_key \
        --value 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe \
        --bridge-address $bridge_address \
        --destination-network 1 \
        --destination-address $target_address \
        --rpc-url $l2_pp2_url \
        --token-address $test_erc20_buggy_addr \
        --force-update-root=true

cast send --legacy --rpc-url $l2_pp2_url --private-key $target_private_key $test_erc20_buggy_addr 'mint(address,uint256)' $target_address $(cast max-uint)
cast send --legacy --rpc-url $l2_pp2_url --private-key $target_private_key $test_erc20_buggy_addr 'setBalanceOf(address,uint256)' $bridge_address 0


curl -s $l2_pp1b_url/bridges/$target_address

# ## Calling through a smart contract of some kind
#
# The idea here is to do some transactions through a proxy or some kind so

lxly_proxy_bytecode=608060405234801561001057600080fd5b50604051610acb380380610acb83398101604081905261002f91610054565b600080546001600160a01b0319166001600160a01b0392909216919091179055610084565b60006020828403121561006657600080fd5b81516001600160a01b038116811461007d57600080fd5b9392505050565b610a38806100936000396000f3fe6080604052600436106100955760003560e01c8063b8b284d011610059578063b8b284d014610196578063ccaa2d11146101c9578063cd586579146101e9578063dd96eab7146101fc578063f5efcd79146101fc57610116565b80631c253d72146101965780631eb5f7aa146101b6578063240ff378146101b65780632c4422ca146101c95780635ea89907146101e957610116565b366101165760008054604051630481fe6f60e31b815263ffffffff34166004820152336024820152600160448201526080606482015260848101929092526001600160a01b03169063240ff3789060a401600060405180830381600087803b15801561010057600080fd5b505af1158015610114573d6000803e3d6000fd5b005b60008054604051630481fe6f60e31b815236916060916001600160a01b039091169063240ff37890610155903490339060019089908990600401610436565b600060405180830381600087803b15801561016f57600080fd5b505af1158015610183573d6000803e3d6000fd5b5050604080516020810190915260009052005b3480156101a257600080fd5b506101146101b136600461056f565b61021c565b6101146101c43660046105e8565b61028d565b3480156101d557600080fd5b506101146101e43660046106c5565b6102fb565b6101146101f7366004610799565b61037e565b34801561020857600080fd5b506101146102173660046106c5565b6103f2565b600054604051630b8b284d60e41b81526001600160a01b039091169063b8b284d0906102549088908890889088908890600401610867565b600060405180830381600087803b15801561026e57600080fd5b505af1158015610282573d6000803e3d6000fd5b505050505050505050565b600054604051630481fe6f60e31b81526001600160a01b039091169063240ff378906102c39087908790879087906004016108ad565b600060405180830381600087803b1580156102dd57600080fd5b505af11580156102f1573d6000803e3d6000fd5b5050505050505050565b60005460405163ccaa2d1160e01b81526001600160a01b039091169063ccaa2d119061033f908e908e908e908e908e908e908e908e908e908e908e9060040161091c565b600060405180830381600087803b15801561035957600080fd5b505af115801561036d573d6000803e3d6000fd5b505050505050505050505050505050565b60005460405163cd58657960e01b81526001600160a01b039091169063cd586579906103b8908990899089908990899089906004016109af565b600060405180830381600087803b1580156103d257600080fd5b505af11580156103e6573d6000803e3d6000fd5b50505050505050505050565b60005460405163f5efcd7960e01b81526001600160a01b039091169063f5efcd799061033f908e908e908e908e908e908e908e908e908e908e908e9060040161091c565b63ffffffff861681526001600160a01b038516602082015283151560408201526080606082018190528101829052818360a0830137600081830160a090810191909152601f909201601f19160101949350505050565b803563ffffffff811681146104a057600080fd5b919050565b80356001600160a01b03811681146104a057600080fd5b803580151581146104a057600080fd5b634e487b7160e01b600052604160045260246000fd5b600082601f8301126104f357600080fd5b813567ffffffffffffffff8082111561050e5761050e6104cc565b604051601f8301601f19908116603f01168101908282118183101715610536576105366104cc565b8160405283815286602085880101111561054f57600080fd5b836020870160208301376000602085830101528094505050505092915050565b600080600080600060a0868803121561058757600080fd5b6105908661048c565b945061059e602087016104a5565b9350604086013592506105b3606087016104bc565b9150608086013567ffffffffffffffff8111156105cf57600080fd5b6105db888289016104e2565b9150509295509295909350565b600080600080608085870312156105fe57600080fd5b6106078561048c565b9350610615602086016104a5565b9250610623604086016104bc565b9150606085013567ffffffffffffffff81111561063f57600080fd5b61064b878288016104e2565b91505092959194509250565b600082601f83011261066857600080fd5b60405161040080820182811067ffffffffffffffff8211171561068d5761068d6104cc565b604052830181858211156106a057600080fd5b845b828110156106ba5780358252602091820191016106a2565b509195945050505050565b60008060008060008060008060008060006109208c8e0312156106e757600080fd5b6106f18d8d610657565b9a506107018d6104008e01610657565b99506108008c013598506108208c013597506108408c013596506107286108608d0161048c565b95506107376108808d016104a5565b94506107466108a08d0161048c565b93506107556108c08d016104a5565b92506108e08c013591506109008c013567ffffffffffffffff81111561077a57600080fd5b6107868e828f016104e2565b9150509295989b509295989b9093969950565b60008060008060008060c087890312156107b257600080fd5b6107bb8761048c565b95506107c9602088016104a5565b9450604087013593506107de606088016104a5565b92506107ec608088016104bc565b915060a087013567ffffffffffffffff81111561080857600080fd5b61081489828a016104e2565b9150509295509295509295565b6000815180845260005b818110156108475760208185018101518683018201520161082b565b506000602082860101526020601f19601f83011685010191505092915050565b63ffffffff8616815260018060a01b0385166020820152836040820152821515606082015260a0608082015260006108a260a0830184610821565b979650505050505050565b63ffffffff851681526001600160a01b038416602082015282151560408201526080606082018190526000906108e590830184610821565b9695505050505050565b8060005b60208082106109025750610916565b8251855293840193909101906001016108f3565b50505050565b600061092061092b838f6108ef565b61093961040084018e6108ef565b61080083018c905261082083018b905261084083018a905263ffffffff8981166108608501526001600160a01b038981166108808601529088166108a085015286166108c08401526108e08301859052610900830181905261099d81840185610821565b9e9d5050505050505050505050505050565b63ffffffff871681526001600160a01b0386811660208301526040820186905284166060820152821515608082015260c060a082018190526000906109f690830184610821565b9897505050505050505056fea2646970667358221220b86e525972f2e2cc9d33328df79fceaa11e88478f9966dde327eeec360259b4964736f6c63430008140033

constructor_args=$(cast abi-encode 'f(address)' $bridge_address | sed 's/0x//')

cast send --legacy --rpc-url $l1_rpc_url --private-key $private_key $deterministic_deployer_addr $salt$lxly_proxy_bytecode$constructor_args
cast send --legacy --rpc-url $l2_pp1_url --private-key $private_key $deterministic_deployer_addr $salt$lxly_proxy_bytecode$constructor_args
cast send --legacy --rpc-url $l2_pp2_url --private-key $private_key $deterministic_deployer_addr $salt$lxly_proxy_bytecode$constructor_args

test_lxly_proxy_addr=$(cast create2 --salt $salt --init-code $lxly_proxy_bytecode$constructor_args)

cast send --legacy --value 2 --rpc-url $l1_rpc_url --private-key $target_private_key $test_lxly_proxy_addr
cast send --legacy --value 3 --rpc-url $l2_pp1_url --private-key $target_private_key $test_lxly_proxy_addr
cast send --legacy --value 1 --rpc-url $l2_pp2_url --private-key $target_private_key $test_lxly_proxy_addr

# In in my test environment I've deployed a contract specifically for
# testing. You might not have this. The idea is to call the bridge
# contract from a bunch of contexts and ensure that things more or
# less still work
tester_contract_address=0xfBE07a394847c26b1d998B6e44EE78A9C8191f13

address_tester_actions="001 002 003 004 011 012 013 014 021 022 023 024 031 032 033 034 041 042 043 044 101 201 301 401 501 601 701 801 901"

for create_mode in 0 1 2; do
    for action in $address_tester_actions ; do
        cast send --legacy --value 1 --rpc-url $l1_rpc_url --private-key $target_private_key $tester_contract_address $(cast abi-encode 'f(uint32, address, uint256)' 0x"$create_mode$action" $test_lxly_proxy_addr 1)
        cast send --legacy --value 2 --rpc-url $l2_pp1_url --private-key $target_private_key $tester_contract_address $(cast abi-encode 'f(uint32, address, uint256)' 0x"$create_mode$action" $test_lxly_proxy_addr 2)
        cast send --legacy --value 1 --rpc-url $l2_pp2_url --private-key $target_private_key $tester_contract_address $(cast abi-encode 'f(uint32, address, uint256)' 0x"$create_mode$action" $test_lxly_proxy_addr 1)
    done
done

# TODO add a test where there is more than uint256 funds
# TODO add some tests with reverting
# TODO add some tests where the bridge is called via a smart contract rather than directly
# TODO add a scneario that does a full sweep of the target account native token and the end to ensure all of the accounting looks good

# ## State Capture Procedure
pushd $(mktemp -d)
mkdir agglayer-storage
docker cp agglayer--f3cc4c8d0bad44be9c0ea8eccedd0da1:/etc/zkevm/storage agglayer-storage/
mkdir cdk-001
docker cp cdk-node-001--bd52b030071a4c438cf82b6c281219e6:/tmp cdk-001/
mkdir cdk-002
docker cp cdk-node-002--3c9a92d0e1aa4259a795d7a60156188c:/tmp cdk-002/
kurtosis enclave dump pp

popd
tar caf agglayer-details.tar.xz /tmp/tmp.VKezDefjS6
