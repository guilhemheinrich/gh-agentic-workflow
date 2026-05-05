#!/usr/bin/env node

/**
 * MCP Configuration Transformer
 * 
 * This script reads MCP server configurations in Cursor format and transforms them
 * to OpenCode and Claude formats. It supports both transforming a specific server
 * or all servers in a configuration file.
 * 
 * Usage:
 *   node transform-mcp.js --from cursor --to opencode --server <server_name> --input <input_file> [--output <output_file>]
 *   node transform-mcp.js --from cursor --to claude-code --input <input_file> [--output <output_file>]
 *   node transform-mcp.js --from cursor --to claude-desktop --input <input_file> [--output <output_file>]
 */

const fs = require('fs');
const path = require('path');
const os = require('os');

// Parse command line arguments
const args = process.argv.slice(2);
const params = {};

for (let i = 0; i < args.length; i += 2) {
  if (args[i].startsWith('--')) {
    params[args[i].substring(2)] = args[i + 1];
  }
}

if (!params.from || !params.to || !params.input) {
  console.error('Required parameters missing. Usage:');
  console.error('node transform-mcp.js --from cursor --to opencode --input <input_file> [--output <output_file>]');
  process.exit(1);
}

// Ensure the from format is supported
if (params.from !== 'cursor') {
  console.error(`Unsupported source format: ${params.from}`);
  console.error('Currently only "cursor" is supported as a source format');
  process.exit(1);
}

// Ensure the to format is supported
const supportedTargets = ['opencode', 'claude-code', 'claude-desktop'];
if (!supportedTargets.includes(params.to)) {
  console.error(`Unsupported target format: ${params.to}`);
  console.error(`Supported targets are: ${supportedTargets.join(', ')}`);
  process.exit(1);
}

// Read input file
let inputContent;
try {
  inputContent = fs.readFileSync(params.input, 'utf8');
} catch (err) {
  console.error(`Error reading input file ${params.input}: ${err.message}`);
  process.exit(1);
}

// Parse JSON
let inputConfig;
try {
  inputConfig = JSON.parse(inputContent);
} catch (err) {
  console.error(`Error parsing JSON from ${params.input}: ${err.message}`);
  process.exit(1);
}

// Transformation functions
function transformCursorToOpenCode(cursorServer, serverName) {
  // OpenCode format uses a "type" field and a command array
  const result = {};
  
  // Determine if this is a local or remote server
  if (cursorServer.url) {
    // Remote server (has URL)
    result.type = 'remote';
    result.enabled = true;
    result.url = cursorServer.url;
    
    // Copy headers if present
    if (cursorServer.headers) {
      result.headers = cursorServer.headers;
    }
  } else if (cursorServer.command) {
    // Local server (has command)
    result.type = 'local';
    result.enabled = true;
    
    // Transform command and args to a single array
    const command = [cursorServer.command];
    if (cursorServer.args && Array.isArray(cursorServer.args)) {
      command.push(...cursorServer.args);
    }
    result.command = command;
    
    // Transform env to environment
    if (cursorServer.env) {
      result.environment = { ...cursorServer.env };
    }
  } else {
    console.warn(`Cannot transform server "${serverName}": missing both url and command`);
    return null;
  }
  
  return result;
}

function transformCursorToClaudeCode(cursorServer, serverName) {
  // Claude Code format is similar to Cursor but adds explicit type
  const result = { ...cursorServer };
  
  if (cursorServer.url) {
    // Remote server (has URL)
    result.type = 'http';
  } else if (cursorServer.command) {
    // Local server (has command)
    result.type = 'stdio';
  } else {
    console.warn(`Cannot transform server "${serverName}": missing both url and command`);
    return null;
  }
  
  return result;
}

function transformCursorToClaudeDesktop(cursorServer, serverName) {
  // Claude Desktop only supports local servers
  if (!cursorServer.command) {
    console.warn(`Skipping remote server "${serverName}" for Claude Desktop (only supports local servers)`);
    return null;
  }
  
  // For local servers, keep the same format as Cursor
  return { ...cursorServer };
}

// Perform the transformation
let outputConfig;

// If transforming a specific server
if (params.server) {
  const serverName = params.server;
  const cursorServer = inputConfig.mcpServers && inputConfig.mcpServers[serverName];
  
  if (!cursorServer) {
    console.error(`Server "${serverName}" not found in the input configuration`);
    process.exit(1);
  }
  
  let transformedServer;
  
  switch (params.to) {
    case 'opencode':
      transformedServer = transformCursorToOpenCode(cursorServer, serverName);
      outputConfig = { mcp: {} };
      if (transformedServer) {
        outputConfig.mcp[serverName] = transformedServer;
      }
      break;
    case 'claude-code':
      transformedServer = transformCursorToClaudeCode(cursorServer, serverName);
      outputConfig = { mcpServers: {} };
      if (transformedServer) {
        outputConfig.mcpServers[serverName] = transformedServer;
      }
      break;
    case 'claude-desktop':
      transformedServer = transformCursorToClaudeDesktop(cursorServer, serverName);
      outputConfig = { mcpServers: {} };
      if (transformedServer) {
        outputConfig.mcpServers[serverName] = transformedServer;
      }
      break;
  }
} else {
  // Transform all servers
  if (!inputConfig.mcpServers) {
    console.error('No mcpServers found in the input configuration');
    process.exit(1);
  }
  
  const serverNames = Object.keys(inputConfig.mcpServers);
  
  switch (params.to) {
    case 'opencode':
      outputConfig = { mcp: {} };
      for (const name of serverNames) {
        const transformed = transformCursorToOpenCode(inputConfig.mcpServers[name], name);
        if (transformed) {
          outputConfig.mcp[name] = transformed;
        }
      }
      break;
    case 'claude-code':
      outputConfig = { mcpServers: {} };
      for (const name of serverNames) {
        const transformed = transformCursorToClaudeCode(inputConfig.mcpServers[name], name);
        if (transformed) {
          outputConfig.mcpServers[name] = transformed;
        }
      }
      break;
    case 'claude-desktop':
      outputConfig = { mcpServers: {} };
      for (const name of serverNames) {
        const transformed = transformCursorToClaudeDesktop(inputConfig.mcpServers[name], name);
        if (transformed) {
          outputConfig.mcpServers[name] = transformed;
        }
      }
      break;
  }
}

// Output the result
const outputJson = JSON.stringify(outputConfig, null, 2);

if (params.output) {
  try {
    fs.writeFileSync(params.output, outputJson);
    console.log(`Transformed configuration written to ${params.output}`);
  } catch (err) {
    console.error(`Error writing to output file ${params.output}: ${err.message}`);
    process.exit(1);
  }
} else {
  // Output to stdout
  console.log(outputJson);
}