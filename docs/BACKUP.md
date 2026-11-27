# Back up a card before you change it

A full copy of the microSD card, taken on a computer, is the surest way
back. These tools read a card into an image file, write an image to a
card, and compare the two byte for byte. They were written for this
project's own cards and are stricter than `dd`: each refuses to run unless
the card is exactly the one you identified.

All commands run on a Linux computer, from this repository's folder, as
your ordinary user. The Nano must be shut down and the card in the
computer's reader.

A card image is as large as the card (about 30 GB for a 32 GB card) and
holds everything on it, passwords and keys included. The tools keep images
under `artifacts/`, which git ignores.

## 1. Identify the card

```bash
lsblk -e 7 -b -o NAME,PATH,SIZE,TYPE,TRAN,MODEL,FSTYPE,LABEL,MOUNTPOINTS
```

Find the card by its size, its transport (`usb` or `mmc`) and its
partitions: a JetPack card has 14, and this project's cards keep that
layout. Do not rely on a device name from an earlier insertion. Unmount
every partition of it that your desktop mounted:

```bash
udisksctl unmount -b /dev/CARD_PARTITION
```

Note its exact size in bytes from the `SIZE` column. Two cards sold as
32 GB are rarely the same size.

## 2. Read it into an image

The tools do not use `sudo`. If your user cannot read the card, grant read
access to that one device node (it disappears when the card is removed):

```bash
sudo setfacl -m "u:$(id -un):r" /dev/CARD
```

```bash
scripts/host/backup-card.sh --device /dev/CARD --expected-bytes BYTES
```

It refuses a card with anything mounted or of a different size, reads the
whole card, and writes the image with its SHA-256 and a record of the run
to `artifacts/backups/`, or to another folder with `--dest DIR`. Accept the
backup only when it ends with `status=PASS`. It never writes to a device.

## 3. Write an image back

This erases the card you name. Identify it again as in step 1, unmount
it, and read its kernel disk sequence, which changes each time a card is
inserted and so proves it is still the same card:

```bash
cat /sys/class/block/CARD/diskseq
sudo setfacl -m "u:$(id -un):rw" /dev/CARD
scripts/host/restore-card.sh --image IMAGE --sha256 IMAGE_SHA256 \
  --device /dev/CARD --expected-bytes BYTES --expected-diskseq SEQUENCE
```

It requires a whole, unmounted USB or MMC card of exactly the image's size
and that disk sequence, checks the image's hash before writing, then reads
every byte back from the card and compares it. Accept the result only with
`readback=PASS` and `status=PASS`.

To compare a card with an image again later, without writing:

```bash
python3 scripts/host/verify-card.py --image IMAGE --sha256 IMAGE_SHA256 \
  --device /dev/CARD --expected-bytes BYTES --expected-diskseq SEQUENCE
```

## A card that is slightly smaller

An image only fits a card at least as large as the one it came from.
[prepare-smaller-image.py](../scripts/host/prepare-smaller-image.py) makes a
copy of a Nano card image that fits a smaller card: it shrinks the main
partition's filesystem in the copy, keeps the 13 boot partitions as they
are and moves the backup partition table. It works on files only and never
changes the original image or a card.

```bash
python3 scripts/host/prepare-smaller-image.py --source IMAGE \
  --source-sha256 IMAGE_SHA256 --target-bytes SMALLER_CARD_BYTES
```

## What a card image does not hold

The Nano's boot firmware lives in a flash chip on the module, not on the
card, so no card image contains it and no restore changes it. This project
never writes it ([docs/SAFETY.md](SAFETY.md)).
