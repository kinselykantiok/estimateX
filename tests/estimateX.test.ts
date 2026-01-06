
import { beforeEach, describe, expect, it } from "vitest";
import { Cl, ClarityType } from "@stacks/transactions";

const contractName = "estimateX";
const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const wallet1 = accounts.get("wallet_1")!;
const wallet2 = accounts.get("wallet_2")!;
const wallet3 = accounts.get("wallet_3")!;

const call = (sender: string, fn: string, args: any[] = []) =>
  simnet.callPublicFn(contractName, fn, args, sender);
const ro = (fn: string, args: any[] = [], sender: string = deployer) =>
  simnet.callReadOnlyFn(contractName, fn, args, sender);
const mine = (blocks = 1) => simnet.mineEmptyBlocks(blocks);
const currentHeight = () => simnet.mineEmptyBlocks(0);
const nextMarketId = (() => {
  let id = 0;
  return () => ++id;
})();

const makeDeadline = (offset = 10) => Cl.uint(currentHeight() + offset);
const unwrapSome = (cv: any) => {
  expect(cv.type).toBe(ClarityType.OptionalSome);
  return (cv as any).value;
};

describe("estimateX core flows", () => {
  beforeEach(() => {
    expect(simnet.blockHeight).toBeDefined();
  });

  describe("owner controls", () => {
    it("only owner can pause/unpause and paused state blocks actions", () => {
      const pauseByNonOwner = call(wallet1, "emergency-pause", [Cl.bool(true)]);
      expect(pauseByNonOwner.result).toBeErr(Cl.uint(114));

      const pause = call(deployer, "emergency-pause", [Cl.bool(true)]);
      expect(pause.result).toBeOk(Cl.bool(true));

      const id = nextMarketId();
      const pausedCreate = call(wallet1, "create-market", [
        Cl.uint(id),
        Cl.stringAscii("Paused market"),
        makeDeadline(15),
      ]);
      expect(pausedCreate.result).toBeErr(Cl.uint(113));

      const unpause = call(deployer, "emergency-pause", [Cl.bool(false)]);
      expect(unpause.result).toBeOk(Cl.bool(true));
    });

    it("owner can update min bet and others cannot", () => {
      const unauthorized = call(wallet1, "update-min-bet", [Cl.uint(2_000_000)]);
      expect(unauthorized.result).toBeErr(Cl.uint(114));

      const update = call(deployer, "update-min-bet", [Cl.uint(2_000_000)]);
      expect(update.result).toBeOk(Cl.bool(true));

      // restore to default for other tests
      const restore = call(deployer, "update-min-bet", [Cl.uint(1_000_000)]);
      expect(restore.result).toBeOk(Cl.bool(true));
    });
  });

  describe("create market", () => {
    it("creates a market with valid params", () => {
      const id = nextMarketId();
      const res = call(wallet1, "create-market", [
        Cl.uint(id),
        Cl.stringAscii("Will it rain?"),
        makeDeadline(20),
      ]);
      expect(res.result).toBeOk(Cl.bool(true));

      const marketCv = ro("get-market", [Cl.uint(id)]).result;
      const market = unwrapSome(marketCv);
      const data = (market as any).value;
      expect(data.creator).toStrictEqual(Cl.principal(wallet1));
      expect(data["yes-pool"]).toBeUint(0);
      expect(data["no-pool"]).toBeUint(0);
      expect(data["min-bet"]).toBeUint(1_000_000);
    });

    it("rejects duplicate ids", () => {
      const id = nextMarketId();
      const first = call(wallet1, "create-market", [
        Cl.uint(id),
        Cl.stringAscii("Duplicate?"),
        makeDeadline(12),
      ]);
      expect(first.result).toBeOk(Cl.bool(true));

      const duplicate = call(wallet2, "create-market", [
        Cl.uint(id),
        Cl.stringAscii("Duplicate?"),
        makeDeadline(12),
      ]);
      expect(duplicate.result).toBeErr(Cl.uint(100));
    });

    it("validates deadline and min bet", () => {
      const idPast = nextMarketId();
      const past = call(wallet1, "create-market", [
        Cl.uint(idPast),
        Cl.stringAscii("Too soon"),
        Cl.uint(currentHeight()), // not strictly greater
      ]);
      expect(past.result).toBeErr(Cl.uint(103));

      const idLong = nextMarketId();
      const tooFar = call(wallet1, "create-market", [
        Cl.uint(idLong),
        Cl.stringAscii("Too far"),
        Cl.uint(currentHeight() + 200_000),
      ]);
      expect(tooFar.result).toBeErr(Cl.uint(103));

      const idMin = nextMarketId();
      const lowMin = call(wallet1, "create-market-enhanced", [
        Cl.uint(idMin),
        Cl.stringAscii("Low min"),
        makeDeadline(15),
        Cl.uint(500_000),
      ]);
      expect(lowMin.result).toBeErr(Cl.uint(102));
    });
  });

  describe("buy flow and pools", () => {
    it("lets users buy yes/no and updates pools and positions", () => {
      const id = nextMarketId();
      const create = call(wallet1, "create-market", [
        Cl.uint(id),
        Cl.stringAscii("Buy flow"),
        makeDeadline(30),
      ]);
      expect(create.result).toBeOk(Cl.bool(true));

      const buyYes = call(wallet2, "buy", [Cl.uint(id), Cl.bool(true), Cl.uint(1_000_000)]);
      expect(buyYes.result).toBeOk(Cl.bool(true));

      const buyNo = call(wallet1, "buy", [Cl.uint(id), Cl.bool(false), Cl.uint(2_000_000)]);
      expect(buyNo.result).toBeOk(Cl.bool(true));

      const market = unwrapSome(ro("get-market", [Cl.uint(id)]).result);
      const data = (market as any).value;
      expect(data["yes-pool"]).toBeUint(1_000_000);
      expect(data["no-pool"]).toBeUint(2_000_000);

      const posYes = unwrapSome(
        ro("get-user-position", [Cl.uint(id), Cl.principal(wallet2)], wallet2).result,
      );
      expect((posYes as any).value["yes-amount"]).toBeUint(1_000_000);
      expect((posYes as any).value["no-amount"]).toBeUint(0);

      const posNo = unwrapSome(
        ro("get-user-position", [Cl.uint(id), Cl.principal(wallet1)], wallet1).result,
      );
      expect((posNo as any).value["no-amount"]).toBeUint(2_000_000);
    });

    it("blocks buys below min bet or after expiry", () => {
      const id = nextMarketId();
      const create = call(wallet1, "create-market", [
        Cl.uint(id),
        Cl.stringAscii("Guarded buys"),
        makeDeadline(3),
      ]);
      expect(create.result).toBeOk(Cl.bool(true));

      const tooSmall = call(wallet2, "buy", [Cl.uint(id), Cl.bool(true), Cl.uint(500_000)]);
      expect(tooSmall.result).toBeErr(Cl.uint(102));

      mine(5);
      const afterDeadline = call(wallet2, "buy", [Cl.uint(id), Cl.bool(true), Cl.uint(1_000_000)]);
      expect(afterDeadline.result).toBeErr(Cl.uint(103));
    });

    it("flags manipulation when a single bet is too large", () => {
      const id = nextMarketId();
      const create = call(wallet1, "create-market", [
        Cl.uint(id),
        Cl.stringAscii("Anti manipulation"),
        makeDeadline(40),
      ]);
      expect(create.result).toBeOk(Cl.bool(true));

      expect(call(wallet2, "buy", [Cl.uint(id), Cl.bool(true), Cl.uint(6_000_000)]).result).toBeOk(
        Cl.bool(true),
      );
      expect(
        call(wallet3, "buy", [Cl.uint(id), Cl.bool(false), Cl.uint(6_000_000)]).result,
      ).toBeOk(Cl.bool(true));

      const blocked = call(wallet2, "buy", [Cl.uint(id), Cl.bool(true), Cl.uint(5_000_000)]);
      expect(blocked.result).toBeErr(Cl.uint(112));

      const allowed = call(wallet2, "buy", [Cl.uint(id), Cl.bool(true), Cl.uint(3_000_000)]);
      expect(allowed.result).toBeOk(Cl.bool(true));
    });
  });

  describe("resolve and claim", () => {
    it("enforces resolve rules", () => {
      const id = nextMarketId();
      const create = call(wallet1, "create-market", [
        Cl.uint(id),
        Cl.stringAscii("Resolve rules"),
        makeDeadline(5),
      ]);
      expect(create.result).toBeOk(Cl.bool(true));

      const wrongCaller = call(wallet2, "resolve-market", [Cl.uint(id), Cl.bool(true)]);
      expect(wrongCaller.result).toBeErr(Cl.uint(106));

      const tooEarly = call(wallet1, "resolve-market", [Cl.uint(id), Cl.bool(true)]);
      expect(tooEarly.result).toBeErr(Cl.uint(107));

      mine(6);
      const ok = call(wallet1, "resolve-market", [Cl.uint(id), Cl.bool(true)]);
      expect(ok.result).toBeOk(Cl.bool(true));

      const alreadyResolved = call(wallet1, "resolve-market", [Cl.uint(id), Cl.bool(false)]);
      expect(alreadyResolved.result).toBeErr(Cl.uint(104));
    });

    it("pays winners, rejects losers, and prevents double claims", () => {
      const id = nextMarketId();
      const create = call(wallet1, "create-market", [
        Cl.uint(id),
        Cl.stringAscii("Claim flow"),
        makeDeadline(5),
      ]);
      expect(create.result).toBeOk(Cl.bool(true));

      expect(call(wallet2, "buy", [Cl.uint(id), Cl.bool(true), Cl.uint(2_000_000)]).result).toBeOk(
        Cl.bool(true),
      );
      expect(
        call(wallet3, "buy", [Cl.uint(id), Cl.bool(false), Cl.uint(1_000_000)]).result,
      ).toBeOk(Cl.bool(true));

      mine(6);
      expect(call(wallet1, "resolve-market", [Cl.uint(id), Cl.bool(true)]).result).toBeOk(
        Cl.bool(true),
      );

      const claimWinner = call(wallet2, "claim-winnings", [Cl.uint(id)]);
      expect(claimWinner.result).toBeOk(Cl.uint(3_000_000));

      const doubleClaim = call(wallet2, "claim-winnings", [Cl.uint(id)]);
      expect(doubleClaim.result).toBeErr(Cl.uint(109));

      const loserClaim = call(wallet3, "claim-winnings", [Cl.uint(id)]);
      expect(loserClaim.result).toBeErr(Cl.uint(108));
    });
  });

  describe("cancel market", () => {
    it("only creator can cancel and cancelled markets are locked", () => {
      const id = nextMarketId();
      const create = call(wallet1, "create-market", [
        Cl.uint(id),
        Cl.stringAscii("Cancelable"),
        makeDeadline(10),
      ]);
      expect(create.result).toBeOk(Cl.bool(true));

      const notCreator = call(wallet2, "cancel-market", [Cl.uint(id)]);
      expect(notCreator.result).toBeErr(Cl.uint(106));

      const cancel = call(wallet1, "cancel-market", [Cl.uint(id)]);
      expect(cancel.result).toBeOk(Cl.bool(true));

      const blockedBuy = call(wallet2, "buy", [Cl.uint(id), Cl.bool(true), Cl.uint(1_000_000)]);
      expect(blockedBuy.result).toBeErr(Cl.uint(110));

      mine(15);
      const blockedResolve = call(wallet1, "resolve-market", [Cl.uint(id), Cl.bool(true)]);
      expect(blockedResolve.result).toBeErr(Cl.uint(110));
    });
  });

  describe("recover funds", () => {
    it("allows recovery after grace period when unresolved", () => {
      const id = nextMarketId();
      const create = call(wallet1, "create-market", [
        Cl.uint(id),
        Cl.stringAscii("Recovery"),
        makeDeadline(5),
      ]);
      expect(create.result).toBeOk(Cl.bool(true));

      expect(call(wallet2, "buy", [Cl.uint(id), Cl.bool(true), Cl.uint(1_000_000)]).result).toBeOk(
        Cl.bool(true),
      );

      const tooEarly = call(wallet2, "recover-funds", [Cl.uint(id)]);
      expect(tooEarly.result).toBeErr(Cl.uint(107));

      mine(14_500);
      const recovered = call(wallet2, "recover-funds", [Cl.uint(id)]);
      expect(recovered.result).toBeOk(Cl.uint(1_000_000));

      const doubleRecovery = call(wallet2, "recover-funds", [Cl.uint(id)]);
      expect(doubleRecovery.result).toBeErr(Cl.uint(109));

      const noPosition = call(wallet3, "recover-funds", [Cl.uint(id)]);
      expect(noPosition.result).toBeErr(Cl.uint(108));
    });
  });
});
