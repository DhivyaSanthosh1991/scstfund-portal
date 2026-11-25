import { JSDOM } from 'jsdom';
import fs from 'fs';

const WEB = new URL('../web/', import.meta.url).pathname;
let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('  ok  ', m); } else { fail++; console.log('  FAIL', m); } };
const tick = (ms = 30) => new Promise(r => setTimeout(r, ms));

// ---- tiny in-memory Supabase mock ----
function makeMock(tables, opts) {
  let n = 0; const uid = () => 'id' + (++n);
  const embeds = { founders: 'application_id', documents: 'application_id', reviews: 'application_id' };
  function builder(table) {
    const st = { op: 'select', filters: [], patch: null, sel: '*', single: false, maybe: false, ret: false };
    const exec = () => {
      const rows = tables[table] || (tables[table] = []);
      const match = r => st.filters.every(([k, v]) => r[k] === v);
      let out = [];
      if (st.op === 'insert') {
        const r = Object.assign({ id: uid(), created_at: new Date().toISOString(), uploaded_at: new Date().toISOString() }, opts.defaults[table] || {}, st.patch);
        if (table === 'applications') r.applicant_id = opts.user.id;
        rows.push(r); out = [r];
      } else if (st.op === 'update') {
        out = rows.filter(match); out.forEach(r => { Object.assign(r, st.patch); if (table === 'reviews') r.updated_at = new Date(Date.now() + (++n)).toISOString(); });
        if (!st.ret) return { data: null, error: null };
      } else if (st.op === 'delete') {
        tables[table] = rows.filter(r => !match(r)); return { data: null, error: null };
      } else out = rows.filter(match);
      out = out.map(r => {
        const c = Object.assign({}, r);
        Object.keys(embeds).forEach(t => { if (st.sel.includes(t + '(')) c[t] = (tables[t] || []).filter(x => x[embeds[t]] === r.id).map(x => Object.assign({}, x)); });
        if (c.reviews) c.reviews = c.reviews[0] || null;
        return c;
      });
      if (st.single) return { data: out[0] || null, error: out[0] ? null : { message: 'none' } };
      if (st.maybe) return { data: out[0] || null, error: null };
      return { data: out, error: null };
    };
    const b = {
      select(s) { if (st.op === 'select') st.sel = s || '*'; else st.ret = true; return b; },
      insert(p) { st.op = 'insert'; st.patch = p; return b; },
      update(p) { st.op = 'update'; st.patch = p; return b; },
      delete() { st.op = 'delete'; return b; },
      eq(k, v) { st.filters.push([k, v]); return b; },
      order() { return b; }, limit() { return b; },
      single() { st.single = true; return b; }, maybeSingle() { st.maybe = true; return b; },
      then(res, rej) { return Promise.resolve(exec()).then(res, rej); }
    };
    return b;
  }
  return {
    createClient: () => ({
      from: builder,
      rpc: async (name, args) => opts.rpc(name, args, tables),
      auth: {
        onAuthStateChange(cb) { setTimeout(() => cb('INITIAL_SESSION', { user: opts.user }), 5); },
        signInWithOtp: async () => ({ error: null }), verifyOtp: async () => ({ error: null }), signOut: async () => ({})
      },
      storage: { from: () => ({ upload: async () => ({ error: null }), remove: async () => ({}), createSignedUrl: async () => ({ data: { signedUrl: 'https://x' } }) }) }
    })
  };
}

async function load(file, mock) {
  const errors = [];
  const html = fs.readFileSync(WEB + file, 'utf8');
  const dom = new JSDOM(html, {
    runScripts: 'dangerously', pretendToBeVisual: true, url: 'https://apply.example.in/',
    beforeParse(w) {
      w.supabase = mock; w.SCST_CONFIG = { supabaseUrl: 'https://abc.supabase.co', supabaseAnonKey: 'k', bucket: 'application-docs', helpEmail: '' };
      w.scrollTo = () => {}; w.open = () => {};
      w.addEventListener('error', e => errors.push(e.message));
    },
    virtualConsole: (() => { const { VirtualConsole } = await_jsdom; const vc = new VirtualConsole(); vc.on('jsdomError', e => errors.push(e.message)); vc.on('error', e => errors.push(String(e))); return vc; })()
  });
  return { dom, w: dom.window, d: dom.window.document, errors };
}
import * as jsdomNS from 'jsdom';
const await_jsdom = jsdomNS;

function setVal(w, el, v, ev = 'input') {
  if (el.type === 'checkbox') el.checked = v; else el.value = v;
  el.dispatchEvent(new w.Event(ev, { bubbles: true }));
  if (ev === 'input') el.dispatchEvent(new w.Event('change', { bubbles: true }));
}
const click = (w, el) => { el.dispatchEvent(new w.MouseEvent('click', { bubbles: true })); };

// ================= APPLY PAGE =================
console.log('Application form');
{
  const tables = { applications: [], founders: [], documents: [] };
  const mock = makeMock(tables, {
    user: { id: 'u-app', email: 'founder@kaveri.in' },
    defaults: { applications: { status: 'draft', revenue_history: [], funds_raised: [], utilisation: [], milestones: [] }, founders: { has_control: false } },
    rpc: async (name, args, t) => { const a = t.applications[0]; return a.legal_name ? { data: 'SCST-2026-0001', error: null } : { data: null, error: { message: 'Please complete: startup legal name' } }; }
  });
  const { w, d, errors } = await load('index.html', mock);
  await tick(120);
  ok(tables.applications.length === 1 && tables.founders.length === 1, 'signing in creates a draft with one founder');
  ok(d.querySelectorAll('.nav button').length === 8, 'eight sections listed');
  setVal(w, d.getElementById('a-legal_name'), 'Kaveri Agro Pvt Ltd');
  setVal(w, d.getElementById('a-district'), 'Krishnagiri', 'change');
  await tick(700);
  ok(tables.applications[0].legal_name === 'Kaveri Agro Pvt Ltd' && tables.applications[0].district === 'Krishnagiri', 'startup fields autosave');
  ok(/Saved/.test(d.getElementById('save').textContent), 'save status shows Saved');

  click(w, d.querySelector('[data-go="1"]')); await tick(80);
  const fid = tables.founders[0].id;
  setVal(w, d.getElementById(`fo-${fid}-full_name`), 'Murugan');
  setVal(w, d.getElementById(`fo-${fid}-community`), 'SC', 'change'); await tick(20);
  setVal(w, d.getElementById(`fo-${fid}-equity_pct`), '40');
  ok(/40%/.test(d.getElementById('meter').textContent) && /Needs more than 50%/.test(d.getElementById('meter').textContent), 'meter flags 40% as not enough');
  ok(!!d.querySelector(`[data-cert="${fid}"]`), 'SC founder gets a community certificate upload');
  click(w, d.querySelector('[data-addf]')); await tick(80);
  const f2 = tables.founders[1].id;
  setVal(w, d.getElementById(`fo-${f2}-community`), 'ST', 'change'); await tick(20);
  setVal(w, d.getElementById(`fo-${f2}-equity_pct`), '15');
  setVal(w, d.getElementById(`fo-${fid}-has_control`), true, 'change');
  const mt = d.getElementById('meter').textContent;
  ok(/55%/.test(mt) && /Meets the more-than-50% equity rule/.test(mt) && /holds management control/.test(mt), 'SC + ST combined 55% with control passes');
  await tick(700);
  ok(Number(tables.founders[0].equity_pct) === 40 && tables.founders[0].has_control === true, 'founder fields autosave');

  click(w, d.querySelector('[data-go="3"]')); await tick(60);
  click(w, d.querySelector('[data-addr="funds_raised"]')); await tick(20);
  setVal(w, d.getElementById('r-funds_raised-0-amount'), '500000');
  setVal(w, d.getElementById('rev-2024-25'), '1200000');
  await tick(700);
  ok(tables.applications[0].funds_raised[0].amount === 500000 && tables.applications[0].revenue_history.find(r => r.fy === '2024-25').revenue === 1200000, 'repeating rows and revenue history save');

  click(w, d.querySelector('[data-go="5"]')); await tick(60);
  setVal(w, d.getElementById('a-ask_amount'), '5000000');
  click(w, d.querySelector('[data-addr="utilisation"]')); await tick(20);
  setVal(w, d.getElementById('r-utilisation-0-amount'), '3000000');
  ok(/₹30,00,000/.test(d.getElementById('util-sum').textContent) && /₹50,00,000/.test(d.getElementById('util-sum').textContent), 'utilisation total compares with the ask in Indian format');

  click(w, d.querySelector('[data-go="6"]')); await tick(60);
  ok(d.querySelectorAll('input[type=file][data-doc]').length === 7, 'seven document slots');

  click(w, d.querySelector('[data-go="7"]')); await tick(60);
  const items = d.querySelectorAll('#checklist li.no').length;
  ok(items > 0 && d.getElementById('submit-btn').disabled, 'submit stays disabled while items are missing (' + items + ' open)');
  ok(/Community certificate for every SC\/ST founder/.test(d.getElementById('checklist').textContent), 'checklist names missing certificates');

  // Pretend everything is filled and submit.
  Object.assign(tables.applications[0], {});
  const appState = tables.applications[0];
  ok(errors.length === 0, 'no script errors on the form' + (errors.length ? ': ' + errors.join(' | ') : ''));
}

// ================= REVIEW PAGE =================
console.log('Review pipeline');
{
  const now = new Date().toISOString();
  const tables = {
    staff: [{ user_id: 'u-staff', email: 's@startuptn.in', full_name: 'Priya', role: 'admin' }],
    applications: [{ id: 'A1', status: 'submitted', app_no: 'SCST-2026-0001', legal_name: 'Kaveri Agro Pvt Ltd', district: 'Krishnagiri', sector: 'AgriTech', submitted_at: now, applicant_email: 'founder@kaveri.in',
      revenue_history: [{ fy: '2024-25', revenue: 1200000 }], funds_raised: [], utilisation: [{ head: 'Machinery', amount: 3000000 }], milestones: [], ask_amount: 5000000, control_details: 'MD is SC', consent_at: now }],
    founders: [{ id: 'F1', application_id: 'A1', position: 0, full_name: 'Murugan', community: 'SC', equity_pct: 40, has_control: true, cert_path: 'u/A1/c.pdf', cert_name: 'c.pdf' },
               { id: 'F2', application_id: 'A1', position: 1, full_name: 'Selvi', community: 'ST', equity_pct: 15, has_control: false, cert_path: 'u/A1/d.pdf', cert_name: 'd.pdf' }],
    documents: [{ id: 'D1', application_id: 'A1', kind: 'pitch_deck', path: 'u/A1/p.pdf', file_name: 'deck.pdf', uploaded_by_staff: false }],
    reviews: [{ application_id: 'A1', stage: 'validation', status: 'active', stage_since: now, data: {}, updated_at: now }],
    activity: []
  };
  const mock = makeMock(tables, { user: { id: 'u-staff', email: 's@startuptn.in' }, defaults: {}, rpc: async () => ({}) });
  const { w, d, errors } = await load('review/index.html', mock);
  await tick(150);
  ok(/Kaveri Agro/.test(d.getElementById('main').textContent), 'staff sees the submitted application');
  click(w, d.querySelector('[data-open="A1"]')); await tick(60);
  ok(!!d.querySelector('.drawer'), 'drawer opens');
  click(w, d.querySelector('[data-tab="application"]')); await tick(20);
  ok(/SC\/ST equity 55%/.test(d.querySelector('.drawer').textContent), 'application tab shows 55% SC/ST equity');
  click(w, d.querySelector('[data-tab="workflow"]')); await tick(20);
  const acc = () => d.querySelector('[data-act="v_accept"]');
  ok(acc() && acc().disabled, 'accept is locked until checks are ticked');
  for (const k of ['certVerified', 'equityVerified', 'controlVerified', 'complete', 'dupChecked']) {
    setVal(w, d.getElementById('f-validation-' + k), true, 'change'); await tick(40);
  }
  ok(tables.reviews[0].data.validation.dupChecked === true, 'validation checks save to the review row');
  ok(acc() && !acc().disabled, 'accept unlocks after all five checks');
  click(w, acc()); await tick(80);
  ok(tables.reviews[0].stage === 'pitch' && tables.reviews[0].data.validation.outcome === 'accepted', 'accept moves to SME pitch and keeps check data');
  ok(tables.activity.length === 1, 'move is written to the activity log');
  setVal(w, d.getElementById('f-pitch-startupStage'), 'prototype', 'change'); await tick(40);
  ok(/not funded under this scheme/.test(d.querySelector('.drawer').textContent), 'prototype stage shows the MSME / reject warning');
  ok(d.querySelector('[data-act="p_bdd"]').disabled, 'BDD recommendation locked for prototype stage');
  click(w, d.querySelector('[data-act="p_msme"]')); await tick(30);
  ok(!!d.getElementById('pend-text'), 'MSME referral asks for a note');
  setVal(w, d.getElementById('pend-text'), 'Trading business, not a startup');
  click(w, d.querySelector('[data-act="confirm"]')); await tick(80);
  ok(tables.reviews[0].status === 'msme' && tables.reviews[0].closed_at_step === 'pitch', 'referral closes the application at the pitch step');
  ok(/Referred to MSME Dept/.test(d.querySelector('.drawer').textContent), 'drawer shows the closed banner');
  // stale write is caught
  tables.reviews[0].updated_at = 'changed-elsewhere';
  click(w, d.querySelector('[data-act="reopen-toggle"]')); await tick(20);
  click(w, d.querySelector('[data-act="reopen"]')); await tick(100);
  ok(tables.reviews[0].status === 'msme', 'a write against a stale version is refused');
  click(w, d.querySelector('[data-act="reopen-toggle"]')); await tick(20);
  click(w, d.querySelector('[data-act="reopen"]')); await tick(100);
  ok(tables.reviews[0].status === 'active' && tables.reviews[0].stage === 'pitch', 'after reload, an admin can reopen');
  ok(errors.length === 0, 'no script errors in the pipeline' + (errors.length ? ': ' + errors.join(' | ') : ''));
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
