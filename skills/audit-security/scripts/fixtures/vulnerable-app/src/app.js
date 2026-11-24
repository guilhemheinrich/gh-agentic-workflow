// DELIBERATELY VULNERABLE test fixture for the audit-security skill.
// Every line below is a planted finding. Never run, never deploy, never copy.
const express = require('express');
const { exec } = require('child_process');
const crypto = require('crypto');
const _ = require('lodash');

const app = express();

// CWE-95: user input reaches eval().
app.get('/calc', (req, res) => {
  const result = eval(req.query.expr);
  res.send(String(result));
});

// CWE-78: user input concatenated into a shell command.
app.get('/ping', (req, res) => {
  exec('ping -c 1 ' + req.query.host, (err, stdout) => res.send(stdout));
});

// CWE-79: user input reflected into HTML without encoding.
app.get('/hello', (req, res) => {
  res.send('<h1>Hello ' + req.query.name + '</h1>');
});

// CWE-601: open redirect.
app.get('/go', (req, res) => {
  res.redirect(req.query.next);
});

// CWE-916: MD5 used to hash a password.
function hashPassword(password) {
  return crypto.createHash('md5').update(password).digest('hex');
}

// CWE-338: Math.random() used for a security token.
function resetToken() {
  return Math.random().toString(36).slice(2);
}

// CWE-639 (IDOR): no check that the invoice belongs to the caller.
// Tools are blind to this one: only the manual checklist finds it.
app.get('/invoices/:id', async (req, res) => {
  const invoice = await db.invoices.findById(req.params.id);
  res.json(invoice);
});

// CWE-1321: reachable use of the vulnerable lodash function (defaultsDeep).
app.post('/settings', express.json(), (req, res) => {
  res.json(_.defaultsDeep({}, req.body));
});

module.exports = { app, hashPassword, resetToken };
