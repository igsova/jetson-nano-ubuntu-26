# Working rules

For anyone changing this repository, people and AI coding assistants alike.
Much of this project was built with AI assistants under these rules.

## Before changing anything

Read [README.md](README.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
and [docs/SAFETY.md](docs/SAFETY.md).

## What counts as evidence

- A hardware claim is true only after it passed on a real Jetson Nano. A PC
  test, an emulator, a compiler version or a clean package install does not
  show that the board works.
- Say what was measured, on what, and when. Mark an estimate or an
  inference as one.
- Keep failures. A result that failed or was never tested stays written
  down as that.

## Safety

- Never write the board's boot firmware (QSPI) or its eFuses, and never
  take a package or script that does.
- Never guess a disk. Identify a card from what the system reports now
  (size, transport, model), have the person confirm it, and refuse
  anything mounted or the disk the system runs from.
- Check every download against a signature or a pinned SHA-256 before
  using it.
- Change one thing at a time, and keep a way back before each change.

## Privacy

- No passwords, keys, addresses, account names, hostnames, serial numbers
  or network names in the repository, in logs or in records.
- Card images, NVIDIA's packages and raw logs go under `artifacts/`, which
  git ignores.

## Where things go

- [scripts/](scripts/README.md): `jetson/` runs on the Nano, `host/` on a
  PC; each script's header says what it does, what it changes and how to
  undo it.
- [patches/jp5](patches/jp5/README.md): one kernel patch per problem, each
  opening with the problem, the fix and the boot that showed it fixed.
- [tests/](tests/README.md): run `python3 tests/convert/test_nano26_convert.py`
  after any change to the converter or to a file it reads.
