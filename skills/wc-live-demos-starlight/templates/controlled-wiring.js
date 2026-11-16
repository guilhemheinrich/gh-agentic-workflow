// Iframe init script: write controlled-component state back so the preview is not frozen.
const el = document.querySelector('my-component'); // replace with the demo element
el.addEventListener('range-change', (e) => { el.date = e.detail.start; });
el.addEventListener('view-change', (e) => { el.view = e.detail.newView; });
