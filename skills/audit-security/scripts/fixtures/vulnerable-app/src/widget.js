// DELIBERATELY VULNERABLE browser-side test fixture for the audit-security skill.

// CWE-79: DOM XSS, location.hash flows into innerHTML.
function renderGreeting() {
  const name = decodeURIComponent(window.location.hash.slice(1));
  document.getElementById('greeting').innerHTML = 'Welcome ' + name;
}

// CWE-346: message handler that never checks event.origin.
window.addEventListener('message', (event) => {
  document.getElementById('panel').innerHTML = event.data;
});

// CWE-922: session token kept in localStorage, readable by any injected script.
function saveSession(token) {
  localStorage.setItem('access_token', token);
}

renderGreeting();
