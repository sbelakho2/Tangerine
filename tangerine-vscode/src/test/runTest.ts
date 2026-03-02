import * as path from 'path';
import * as fs from 'fs';

async function main(): Promise<void> {
    const extensionJs = path.resolve(__dirname, '..', 'extension.js');

    if (!fs.existsSync(extensionJs)) {
        throw new Error(`Compiled extension not found at ${extensionJs}`);
    }

    console.log('Tangerine extension smoke test passed');
}

main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
});
