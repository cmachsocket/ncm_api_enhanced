// assets/bridge/package-addons.mjs
//
// Package Bare native addon .so files into ABI-specific JAR files.
//
// Input:
//
//   android/addons/<abi>/*.so
//
// Output:
//
//   android/addons-jars/<abi>.jar
//
// JAR layout:
//
//   lib/<abi>/libbare-xxx.so
//
// The resulting JARs can be consumed by Gradle:
//
//   implementation fileTree(
//     dir: "addons-jars",
//     include: ["*.jar"]
//   )
//
// No third-party dependencies are required.
//

import { dirname, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";
import {
  mkdir,
  readdir,
  readFile,
  writeFile,
} from "node:fs/promises";
import { stderr, stdout, exit } from "node:process";

//
// --------------------------------------------------------------------------
// Paths
// --------------------------------------------------------------------------
//

const scriptDir = dirname(fileURLToPath(import.meta.url));

const packageRoot = resolvePath(scriptDir, "..", "..");

const addonsRoot = resolvePath(
  packageRoot,
  "android",
  "addons",
);

const jarsRoot = resolvePath(
  packageRoot,
  "android",
  "addons-jars",
);

//
// --------------------------------------------------------------------------
// ABI configuration
// --------------------------------------------------------------------------
//

const ABIS = [
  "arm64-v8a",
  "armeabi-v7a",
  "x86_64",
  "x86",
];

//
// --------------------------------------------------------------------------
// ZIP32 limits
// --------------------------------------------------------------------------
//

const UINT16_MAX = 0xffff;
const UINT32_MAX = 0xffffffff;

//
// --------------------------------------------------------------------------
// CRC-32
// --------------------------------------------------------------------------
//

const crcTable = (() => {
  const table = new Uint32Array(256);

  for (let n = 0; n < 256; n++) {
    let c = n;

    for (let k = 0; k < 8; k++) {
      c =
        c & 1
          ? 0xedb88320 ^ (c >>> 1)
          : c >>> 1;
    }

    table[n] = c >>> 0;
  }

  return table;
})();

function crc32(buffer) {
  let c = 0xffffffff;

  for (let i = 0; i < buffer.length; i++) {
    c =
      crcTable[(c ^ buffer[i]) & 0xff] ^
      (c >>> 8);
  }

  return (c ^ 0xffffffff) >>> 0;
}

//
// --------------------------------------------------------------------------
// DOS timestamp
// --------------------------------------------------------------------------
//

function getDosDateTime() {
  const now = new Date();

  const time =
    Math.floor(now.getSeconds() / 2) |
    (now.getMinutes() << 5) |
    (now.getHours() << 11);

  const year = Math.max(
    1980,
    Math.min(2107, now.getFullYear()),
  );

  const date =
    now.getDate() |
    ((now.getMonth() + 1) << 5) |
    ((year - 1980) << 9);

  return {
    time,
    date,
  };
}

//
// --------------------------------------------------------------------------
// Build JAR
// --------------------------------------------------------------------------
//
// JAR is ZIP.
//
// We use:
//
//   compression method = STORE (0)
//
// No DEFLATE is necessary because native .so files are already binary
// artifacts and compression would add CPU/time without much benefit.
//

async function buildJar(abi, filenames) {
  const { time: dosTime, date: dosDate } =
    getDosDateTime();

  const entries = [];

  let offset = 0;

  //
  // ------------------------------------------------------------------------
  // Local file entries
  // ------------------------------------------------------------------------
  //

  for (const filename of filenames) {
    const entryName = `lib/${abi}/${filename}`;

    //
    // IMPORTANT:
    //
    // Do NOT use:
    //
    //   new TextEncoder().encode(...)
    //
    // because that returns Uint8Array.
    //
    // The ZIP writer below uses Buffer.copy(), so the filename must
    // explicitly be a Node.js Buffer.
    //

    const nameBuffer = Buffer.from(
      entryName,
      "utf8",
    );

    const data = await readFile(
      resolvePath(
        addonsRoot,
        abi,
        filename,
      ),
    );

    const crc = crc32(data);

    //
    // ZIP32 only supports 32-bit sizes/offsets.
    //

    if (data.length > UINT32_MAX) {
      throw new Error(
        `File too large for ZIP32: ${filename}`,
      );
    }

    if (nameBuffer.length > UINT16_MAX) {
      throw new Error(
        `Filename too long for ZIP32: ${entryName}`,
      );
    }

    if (offset > UINT32_MAX) {
      throw new Error(
        `JAR offset exceeds ZIP32 limit before: ${filename}`,
      );
    }

    //
    // Local File Header
    //
    // Signature        4
    // Version          2
    // Flags            2
    // Compression      2
    // Time             2
    // Date             2
    // CRC32            4
    // Compressed size  4
    // Uncompressed     4
    // Name length      2
    // Extra length     2
    //
    // Total: 30 bytes
    //

    const localHeader = Buffer.alloc(30);

    localHeader.writeUInt32LE(
      0x04034b50,
      0,
    );

    // Version needed.
    localHeader.writeUInt16LE(
      20,
      4,
    );

    // General purpose bit flag.
    localHeader.writeUInt16LE(
      0,
      6,
    );

    // Compression method: STORE.
    localHeader.writeUInt16LE(
      0,
      8,
    );

    localHeader.writeUInt16LE(
      dosTime,
      10,
    );

    localHeader.writeUInt16LE(
      dosDate,
      12,
    );

    localHeader.writeUInt32LE(
      crc,
      14,
    );

    localHeader.writeUInt32LE(
      data.length,
      18,
    );

    localHeader.writeUInt32LE(
      data.length,
      22,
    );

    localHeader.writeUInt16LE(
      nameBuffer.length,
      26,
    );

    // Extra length.
    localHeader.writeUInt16LE(
      0,
      28,
    );

    entries.push({
      name: entryName,
      nameBuffer,
      data,
      crc,
      size: data.length,
      offset,
      localHeader,
    });

    offset +=
      localHeader.length +
      nameBuffer.length +
      data.length;

    if (offset > UINT32_MAX) {
      throw new Error(
        `JAR exceeds ZIP32 limit after: ${filename}`,
      );
    }
  }

  //
  // ------------------------------------------------------------------------
  // Central directory
  // ------------------------------------------------------------------------
  //

  const centralDirectory = [];

  for (const entry of entries) {
    //
    // Central Directory File Header
    //
    // Total: 46 bytes + filename
    //

    const header = Buffer.alloc(46);

    header.writeUInt32LE(
      0x02014b50,
      0,
    );

    // Version made by.
    header.writeUInt16LE(
      20,
      4,
    );

    // Version needed.
    header.writeUInt16LE(
      20,
      6,
    );

    // Flags.
    header.writeUInt16LE(
      0,
      8,
    );

    // Compression: STORE.
    header.writeUInt16LE(
      0,
      10,
    );

    header.writeUInt16LE(
      dosTime,
      12,
    );

    header.writeUInt16LE(
      dosDate,
      14,
    );

    header.writeUInt32LE(
      entry.crc,
      16,
    );

    header.writeUInt32LE(
      entry.size,
      20,
    );

    header.writeUInt32LE(
      entry.size,
      24,
    );

    header.writeUInt16LE(
      entry.nameBuffer.length,
      28,
    );

    // Extra length.
    header.writeUInt16LE(
      0,
      30,
    );

    // Comment length.
    header.writeUInt16LE(
      0,
      32,
    );

    // Disk number.
    header.writeUInt16LE(
      0,
      34,
    );

    // Internal attributes.
    header.writeUInt16LE(
      0,
      36,
    );

    // External attributes.
    header.writeUInt32LE(
      0,
      38,
    );

    // Relative offset of local header.
    header.writeUInt32LE(
      entry.offset,
      42,
    );

    centralDirectory.push({
      header,
      nameBuffer: entry.nameBuffer,
    });
  }

  const centralSize =
    centralDirectory.reduce(
      (size, entry) =>
        size +
        entry.header.length +
        entry.nameBuffer.length,
      0,
    );

  const centralOffset = offset;

  if (centralSize > UINT32_MAX) {
    throw new Error(
      `Central directory exceeds ZIP32 limit: ${centralSize}`,
    );
  }

  if (centralOffset > UINT32_MAX) {
    throw new Error(
      `Central directory offset exceeds ZIP32 limit: ${centralOffset}`,
    );
  }

  if (entries.length > UINT16_MAX) {
    throw new Error(
      `Too many entries for ZIP32: ${entries.length}`,
    );
  }

  //
  // ------------------------------------------------------------------------
  // End of Central Directory
  // ------------------------------------------------------------------------
  //

  const eocd = Buffer.alloc(22);

  eocd.writeUInt32LE(
    0x06054b50,
    0,
  );

  // Disk number.
  eocd.writeUInt16LE(
    0,
    4,
  );

  // Central directory disk.
  eocd.writeUInt16LE(
    0,
    6,
  );

  // Entries on this disk.
  eocd.writeUInt16LE(
    entries.length,
    8,
  );

  // Total entries.
  eocd.writeUInt16LE(
    entries.length,
    10,
  );

  // Central directory size.
  eocd.writeUInt32LE(
    centralSize,
    12,
  );

  // Central directory offset.
  eocd.writeUInt32LE(
    centralOffset,
    16,
  );

  // Comment length.
  eocd.writeUInt16LE(
    0,
    20,
  );

  //
  // ------------------------------------------------------------------------
  // Assemble
  // ------------------------------------------------------------------------
  //

  const totalSize =
    centralOffset +
    centralSize +
    eocd.length;

  if (totalSize > UINT32_MAX) {
    throw new Error(
      `JAR exceeds ZIP32 limit: ${totalSize} bytes`,
    );
  }

  const output = Buffer.alloc(totalSize);

  let cursor = 0;

  //
  // Local entries.
  //

  for (const entry of entries) {
    entry.localHeader.copy(
      output,
      cursor,
    );

    cursor += entry.localHeader.length;

    //
    // nameBuffer is guaranteed to be a Node Buffer.
    //

    entry.nameBuffer.copy(
      output,
      cursor,
    );

    cursor += entry.nameBuffer.length;

    entry.data.copy(
      output,
      cursor,
    );

    cursor += entry.data.length;
  }

  //
  // Central directory.
  //

  for (const entry of centralDirectory) {
    entry.header.copy(
      output,
      cursor,
    );

    cursor += entry.header.length;

    //
    // nameBuffer is guaranteed to be a Node Buffer.
    //

    entry.nameBuffer.copy(
      output,
      cursor,
    );

    cursor += entry.nameBuffer.length;
  }

  //
  // EOCD.
  //

  eocd.copy(
    output,
    cursor,
  );

  return output;
}

//
// --------------------------------------------------------------------------
// Package one ABI
// --------------------------------------------------------------------------
//

async function packageAbi(abi) {
  const sourceDir = resolvePath(
    addonsRoot,
    abi,
  );

  let entries;

  try {
    entries = await readdir(
      sourceDir,
      {
        withFileTypes: true,
      },
    );
  } catch (error) {
    if (error?.code === "ENOENT") {
      stderr.write(
        `[package-addons] ${abi}: directory does not exist, skipping\n`,
      );

      return false;
    }

    throw error;
  }

  const filenames = entries
    .filter(
      (entry) =>
        entry.isFile() &&
        entry.name.endsWith(".so"),
    )
    .map((entry) => entry.name)
    .sort();

  if (filenames.length === 0) {
    stderr.write(
      `[package-addons] ${abi}: no .so files, skipping\n`,
    );

    return false;
  }

  stdout.write(
    `[package-addons] ${abi}: ${filenames.length} native addons\n`,
  );

  for (const filename of filenames) {
    stdout.write(
      `  ${filename}\n`,
    );
  }

  const jar = await buildJar(
    abi,
    filenames,
  );

  await mkdir(
    jarsRoot,
    {
      recursive: true,
    },
  );

  const outputPath = resolvePath(
    jarsRoot,
    `${abi}.jar`,
  );

  await writeFile(
    outputPath,
    jar,
  );

  stdout.write(
    `[package-addons] wrote ${outputPath} (${jar.length} bytes)\n`,
  );

  return true;
}

//
// --------------------------------------------------------------------------
// Main
// --------------------------------------------------------------------------
//

async function main() {
  stdout.write(
    `[package-addons] input:  ${addonsRoot}\n`,
  );

  stdout.write(
    `[package-addons] output: ${jarsRoot}\n`,
  );

  let count = 0;

  for (const abi of ABIS) {
    if (await packageAbi(abi)) {
      count++;
    }
  }

  stdout.write(
    `[package-addons] packaged ${count}/${ABIS.length} ABIs\n`,
  );
}

try {
  await main();
} catch (error) {
  stderr.write(
    "\n[package-addons] failed\n",
  );

  stderr.write(
    `${error?.stack || error}\n`,
  );

  exit(1);
}
