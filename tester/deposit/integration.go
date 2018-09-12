package plasma

import (
	"crypto/ecdsa"
	"log"
	"math/big"
	"path"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/kyokan/plasma/chain"
	"github.com/kyokan/plasma/util"
	"github.com/syndtr/goleveldb/leveldb"
	"github.com/syndtr/goleveldb/leveldb/opt"
	"gopkg.in/urfave/cli.v1"
)

func IntegrationTest(c *cli.Context) {
	contractAddress := c.GlobalString("contract-addr")
	nodeURL := c.GlobalString("node-url")
	keystoreDir := c.GlobalString("keystore-dir")
	keystoreFile := c.GlobalString("keystore-file")
	userAddress := c.GlobalString("user-address")
	privateKey := c.GlobalString("private-key")
	signPassphrase := c.GlobalString("sign-passphrase")
	dburl := c.GlobalString("db")

	var privateKeyECDSA *ecdsa.PrivateKey

	if exists(userAddress) && exists(privateKey) {
		privateKeyECDSA = util.ToPrivateKeyECDSA(privateKey)
	} else if exists(keystoreDir) &&
		exists(keystoreFile) &&
		exists(userAddress) {
		keyWrapper := util.GetFromKeyStore(userAddress, keystoreDir, keystoreFile, signPassphrase)
		privateKeyECDSA = keyWrapper.PrivateKey
	}

	if privateKeyECDSA == nil {
		log.Fatalln("Private key ecdsa not found")
	}

	plasma := CreatePlasmaClient(nodeURL, contractAddress)

	depositValue := 1000000000

	currentBlock := CurrentChildBlock(plasma, userAddress)

	log.Println("Blockheight before deposit:", currentBlock)

	t := createDepositTx(userAddress, depositValue)
	Deposit(plasma, privateKeyECDSA, userAddress, 1000000000, &t)

	time.Sleep(1 * time.Second)

	currentBlockNew := CurrentChildBlock(plasma, userAddress)

	log.Println("Blockheight after deposit:", currentBlockNew)
	loc := path.Join(dburl, "db")
	o := new(opt.Options)
	o.ReadOnly = true
	log.Println(o.GetReadOnly())
	db, err := leveldb.OpenFile(loc, o)

	if err != nil {
		log.Println("shit %s", err)
	}
	defer db.Close()

}

func exists(str string) bool {
	return len(str) > 0
}

func createDepositTx(userAddress string, value int) chain.Transaction {
	return createTestTransaction(
		chain.ZeroInput(),
		&chain.Output{
			NewOwner: common.HexToAddress(userAddress),
			Amount:   util.NewInt(value),
		},
	)
}

func createTestTransaction(
	input0 *chain.Input,
	output0 *chain.Output,
) chain.Transaction {
	return chain.Transaction{
		Input0:  input0,
		Input1:  chain.ZeroInput(),
		Sig0:    []byte{},
		Sig1:    []byte{},
		Output0: output0,
		Output1: chain.ZeroOutput(),
		Fee:     new(big.Int),
		BlkNum:  uint64(0),
		TxIdx:   0,
	}
}
