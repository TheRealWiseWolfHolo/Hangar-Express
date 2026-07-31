import { readFile, writeFile } from "node:fs/promises";
import {
  buildCuratedImportSQL,
  validateCuratedDictionary,
} from "../src/dictionary.ts";

async function main(): Promise<void> {
  const [inputPath, outputPath] = process.argv.slice(2);
  if (!inputPath || !outputPath) {
    throw new Error(
      "Usage: node scripts/build-curated-import.ts <dictionary.json> <output.sql>",
    );
  }

  const input = JSON.parse(await readFile(inputPath, "utf8")) as unknown;
  const dictionary = await validateCuratedDictionary(input);
  const sql = await buildCuratedImportSQL(dictionary, new Date());
  await writeFile(outputPath, sql, "utf8");

  process.stdout.write(
    `${JSON.stringify({
      locale: dictionary.locale,
      version: dictionary.version,
      generatedAt: dictionary.generatedAt ?? null,
      entries: dictionary.count,
      aliases: dictionary.entries.reduce(
        (total, entry) => total + entry.aliases.length,
        0,
      ),
      checksum: dictionary.checksum,
      outputPath,
    })}\n`,
  );
}

await main();
