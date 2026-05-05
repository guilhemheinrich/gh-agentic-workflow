#!/usr/bin/env node

/**
 * MCP Configuration Merger
 * 
 * This script merges MCP server configurations from a source file into a target file,
 * preserving existing configurations in the target that aren't in the source.
 * 
 * Usage:
 *   node merge-mcp.js --source <source_file> --target <target_file> --format <format> [--output <output_file>]
 * 
 * Where format is one of: opencode, claude-code, claude-desktop
 */

const fs = require('fs');
const path = require('path');

// Parse command line arguments
const args = process.argv.slice(2);
const params = {};

for (let i = 0; i < args.length; i += 2) {
  if (args[i].startsWith('--')) {
    params[args[i].substring(2)] = args[i + 1];
  }
}

if (!params.source || !params.format) {
  console.error('Required parameters missing. Usage:');
  console.error('node merge-mcp.js --source <source_file> --target <target_file> --format <format> [--output <output_file>]');
  process.exit(1);
}

// Ensure the format is supported
const supportedFormats = ['opencode', 'claude-code', 'claude-desktop'];
if (!supportedFormats.includes(params.format)) {
  console.error(`Unsupported format: ${params.format}`);
  console.error(`Supported formats are: ${supportedFormats.join(', ')}`);
  process.exit(1);
}

// Read source file
let sourceContent;
try {
  sourceContent = fs.readFileSync(params.source, 'utf8');
} catch (err) {
  console.error(`Error reading source file ${params.source}: ${err.message}`);
  process.exit(1);
}

// Parse JSON from source
let sourceConfig;
try {
  sourceConfig = JSON.parse(sourceContent);
} catch (err) {
  console.error(`Error parsing JSON from ${params.source}: ${err.message}`);
  process.exit(1);
}

// Read target file if it exists
let targetConfig = {};
if (params.target && fs.existsSync(params.target)) {
  try {
    const targetContent = fs.readFileSync(params.target, 'utf8');
    targetConfig = JSON.parse(targetContent);
  } catch (err) {
    console.warn(`Warning: Could not read or parse target file ${params.target}: ${err.message}`);
    console.warn('Proceeding with an empty target configuration.');
  }
}

// Merge configurations based on the format
let mergedConfig = { ...targetConfig };

switch (params.format) {
  case 'opencode':
    // OpenCode format uses { "mcp": { ... } }
    if (!mergedConfig.mcp) {
      mergedConfig.mcp = {};
    }
    
    // Merge MCP servers from source
    if (sourceConfig.mcp) {
      mergedConfig.mcp = { ...mergedConfig.mcp, ...sourceConfig.mcp };
    }
    break;
    
  case 'claude-code':
  case 'claude-desktop':
    // Claude formats use { "mcpServers": { ... } }
    if (!mergedConfig.mcpServers) {
      mergedConfig.mcpServers = {};
    }
    
    // Merge MCP servers from source
    if (sourceConfig.mcpServers) {
      mergedConfig.mcpServers = { ...mergedConfig.mcpServers, ...sourceConfig.mcpServers };
    }
    break;
}

// Output the merged configuration
const outputJson = JSON.stringify(mergedConfig, null, 2);

if (params.output) {
  try {
    fs.writeFileSync(params.output, outputJson);
    console.log(`Merged configuration written to ${params.output}`);
  } catch (err) {
    console.error(`Error writing to output file ${params.output}: ${err.message}`);
    process.exit(1);
  }
} else {
  // Use the target file as output if specified
  if (params.target) {
    try {
      fs.writeFileSync(params.target, outputJson);
      console.log(`Merged configuration written to ${params.target}`);
    } catch (err) {
      console.error(`Error writing to target file ${params.target}: ${err.message}`);
      process.exit(1);
    }
  } else {
    // Output to stdout
    console.log(outputJson);
  }
}