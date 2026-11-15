# Handoff — common commands
# `make install` is the only setup step needed after cloning.

.PHONY: install build test demo verify clean

install:
	forge install foundry-rs/forge-std --no-commit

build:
	forge build

test: build
	forge test --match-path test/Handoff.t.sol -vv --fork-url https://rpc.test.mezo.org

# Runs the suite against the LIVE deployed router instead of a local copy.
test-deployed: build
	HANDOFF_ROUTER=0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762 \
	forge test --match-path test/Handoff.t.sol -vv --fork-url https://rpc.test.mezo.org

# Serve the frontend at http://localhost:8080
demo:
	python3 -m http.server 8080 --directory web

verify:
	@echo "contract : 0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762"
	@echo "codehash : $$(cast keccak $$(cast code 0x2d2c1B42a75Cf360Ba3A70Bd6ad3a3C619069762 --rpc-url https://rpc.test.mezo.org))"
	@echo "expected : 0xbaec09e54ddfd78eee5a79e41558d731b12a9ae54717b1627bd07c792624b546"

clean:
	forge clean
	rm -rf cache out broadcast
