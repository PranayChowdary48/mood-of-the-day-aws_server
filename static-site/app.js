async function fetchMood() {
  const res = await fetch('/api/mood', { method: 'GET' });
  if (!res.ok) {
    throw new Error('api/mood failed: ' + res.status);
  }
  return res.json();
}

function renderMood(data) {
  document.getElementById('mood').textContent = data.mood;
  document.getElementById('gif').src = data.gif;
  document.getElementById('meta').textContent =
    'generated_at=' + data.generated_at + ' hostname=' + data.hostname + ' cache=' + data.cache_status;
}

function setStatus(message) {
  document.getElementById('status').textContent = message;
}

async function refreshMood() {
  const user = prompt('Refresh username');
  const pass = prompt('Refresh password');
  if (!user || !pass) {
    setStatus('Refresh cancelled.');
    return;
  }
  const auth = btoa(user + ':' + pass);
  const res = await fetch('/api/refresh', {
    method: 'POST',
    headers: { Authorization: 'Basic ' + auth },
  });

  let body = '';
  try {
    body = await res.text();
  } catch (e) {
    body = '<no body>';
  }

  setStatus('refresh status=' + res.status + '\n' + body);
  await loadMood();
}

async function loadMood() {
  try {
    const data = await fetchMood();
    renderMood(data);
    setStatus('ok');
  } catch (err) {
    setStatus(String(err));
  }
}

document.getElementById('refreshBtn').addEventListener('click', refreshMood);
document.getElementById('reloadBtn').addEventListener('click', loadMood);

loadMood();
