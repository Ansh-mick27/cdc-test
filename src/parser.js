/* Excel/CSV parsing for question banks and student lists. Needs XLSX (SheetJS). */
(function (root) {
  const LETTERS = ['a', 'b', 'c', 'd', 'e', 'f'];
  const norm = s => String(s == null ? '' : s).replace(/ /g, ' ').trim().toLowerCase().replace(/\s+/g, ' ');
  const clean = s => String(s == null ? '' : s).replace(/ /g, ' ').trim();
  const rowsOf = ws => root.XLSX.utils.sheet_to_json(ws, { header: 1, defval: '', raw: false, blankrows: false });

  function findCol(h, regs, skip) {
    for (const re of regs) {
      const i = h.findIndex((x, j) => re.test(x) && !(skip && skip.includes(j)));
      if (i >= 0) return i;
    }
    return -1;
  }
  const RE = {
    qno: [/^(question|ques|q)\.? ?(no|number|num|#)\.?$/, /^(s\.? ?no|sr\.? ?no|sl\.? ?no|no\.?|#|qno|q\.no\.?)$/],
    topic: [/topic/, /subject/, /category/, /^section$/],
    question: [/^questions?$/, /^question (text|statement)$/, /^(ques|q)$/, /^question\b(?!.*\b(no|number|num|#)\b)/],
    correctOpt: [/^correct (option|opt\.?|choice)$/, /^(answer|ans) (option|key)$/, /^(answer|ans|key|answer key)$/, /^correct$/, /^right (option|answer)$/],
    correctText: [/^correct answer$/, /^answer text$/],
  };
  const optRe = L => [new RegExp('^(option|opt\\.?|choice) ?\\(?' + L + '\\)?$'), new RegExp('^\\(?' + L + '\\)?$')];

  function headerInfo(row) {
    const h = row.map(norm);
    const qno = findCol(h, RE.qno);
    const question = findCol(h, RE.question, [qno]);
    const opts = [];
    for (const L of LETTERS) { const i = findCol(h, optRe(L)); if (i < 0) break; opts.push(i); }
    return {
      h, qno, question, opts,
      topic: findCol(h, RE.topic),
      correctOpt: findCol(h, RE.correctOpt),
      correctText: findCol(h, RE.correctText),
    };
  }

  function letterIndex(v) {
    const m = /^(?:option|opt\.?)?\s*\(?([a-f])\)?\.?$/i.exec(clean(v));
    return m ? m[1].toLowerCase().charCodeAt(0) - 97 : -1;
  }
  const sameText = (a, b) => norm(a).replace(/[.\s]+$/, '') === norm(b).replace(/[.\s]+$/, '');

  function resolveCorrect(optVal, textVal, options) {
    let i = letterIndex(optVal);
    if (i >= 0 && i < options.length) return i;
    if (clean(textVal)) { i = options.findIndex(o => sameText(o, textVal)); if (i >= 0) return i; }
    if (clean(optVal)) {
      i = options.findIndex(o => sameText(o, optVal)); if (i >= 0) return i;
      if (/^[1-6]$/.test(clean(optVal)) && +clean(optVal) <= options.length) return +clean(optVal) - 1;
    }
    return -1;
  }

  const cleanTopic = t => clean(t).replace(/^\d+\s*[.)\-:]\s*/, '').replace(/\s*\(\s*%\s*\)\s*$/, '').trim();

  /* Returns {questions:[{topic,text,options,correct}], errors:[], sheet, keySheet} */
  function parseQuestions(wb) {
    let qs = null;
    for (const name of wb.SheetNames) {
      const rows = rowsOf(wb.Sheets[name]);
      for (let r = 0; r < Math.min(rows.length, 15); r++) {
        const info = headerInfo(rows[r]);
        if (info.question >= 0 && info.opts.length >= 2) { qs = { name, rows, r, info }; break; }
      }
      if (qs) break;
    }
    if (!qs) return { questions: [], errors: ['Could not find a sheet with "Question" and "Option A / Option B…" columns.'] };

    const { info } = qs;
    // Answer key: in the same sheet, or in another sheet keyed by question number.
    let key = null, keySheet = null;
    if (info.correctOpt < 0 && info.correctText < 0) {
      for (const name of wb.SheetNames) {
        if (name === qs.name) continue;
        const rows = rowsOf(wb.Sheets[name]);
        for (let r = 0; r < Math.min(rows.length, 15); r++) {
          const ki = headerInfo(rows[r]);
          if (ki.qno >= 0 && (ki.correctOpt >= 0 || ki.correctText >= 0)) {
            key = new Map();
            for (const row of rows.slice(r + 1)) {
              const k = norm(row[ki.qno]);
              if (k) key.set(k, { opt: ki.correctOpt >= 0 ? row[ki.correctOpt] : '', text: ki.correctText >= 0 ? row[ki.correctText] : '' });
            }
            keySheet = name;
            break;
          }
        }
        if (key) break;
      }
    }

    const questions = [], errors = [];
    if (info.correctOpt < 0 && info.correctText < 0 && !key)
      errors.push('No answer column found. Add a "Correct Option" column (A/B/C/D) or an "Answer Key" sheet.');

    let n = 0;
    for (const row of qs.rows.slice(qs.r + 1)) {
      const text = clean(row[info.question]);
      if (!text) continue;
      n++;
      const label = info.qno >= 0 && clean(row[info.qno]) ? 'Q' + clean(row[info.qno]) : 'Row ' + n;
      let options = info.opts.map(i => clean(row[i]));
      while (options.length && !options[options.length - 1]) options.pop();
      if (options.length < 2 || options.some(o => !o)) { errors.push(label + ': needs at least 2 options with no blanks.'); continue; }
      let optVal = '', textVal = '';
      if (info.correctOpt >= 0 || info.correctText >= 0) {
        optVal = info.correctOpt >= 0 ? row[info.correctOpt] : '';
        textVal = info.correctText >= 0 ? row[info.correctText] : '';
      } else if (key) {
        const k = key.get(norm(row[info.qno]));
        if (k) { optVal = k.opt; textVal = k.text; }
      }
      const correct = resolveCorrect(optVal, textVal, options);
      if (correct < 0) { errors.push(label + ': correct answer missing or not one of the options.'); continue; }
      questions.push({ topic: info.topic >= 0 ? cleanTopic(row[info.topic]) : '', text, options, correct });
    }
    return { questions, errors, sheet: qs.name, keySheet };
  }

  /* Returns {students:[{email,name,roll}], errors:[]} */
  function parseStudents(wb) {
    const emailRe = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
    const out = new Map(), errors = [];
    for (const name of wb.SheetNames) {
      const rows = rowsOf(wb.Sheets[name]);
      let hr = -1, ce = -1, cn = -1, cr = -1;
      for (let r = 0; r < Math.min(rows.length, 15); r++) {
        const h = rows[r].map(norm);
        const e = h.findIndex(x => /e-?mail|mail id/.test(x));
        if (e >= 0) {
          hr = r; ce = e;
          cn = h.findIndex((x, j) => j !== e && /name/.test(x) && !/(user|file|father|mother|parent)/.test(x));
          cr = h.findIndex((x, j) => j !== e && /(roll|enrol|enroll|reg|admission|^id$|student id)/.test(x));
          break;
        }
      }
      const body = hr >= 0 ? rows.slice(hr + 1) : rows;
      for (const row of body) {
        let email = '';
        if (ce >= 0) email = clean(row[ce]).toLowerCase();
        else { const c = row.find(v => emailRe.test(clean(v))); email = c ? clean(c).toLowerCase() : ''; }
        if (!email) continue;
        if (!emailRe.test(email)) { errors.push('Skipped invalid email: ' + email); continue; }
        out.set(email, { email, name: cn >= 0 ? clean(row[cn]) : '', roll: cr >= 0 ? clean(row[cr]) : '' });
      }
      if (out.size) break;
    }
    return { students: [...out.values()], errors };
  }

  root.CTParser = { parseQuestions, parseStudents, cleanTopic };
})(typeof window !== 'undefined' ? window : globalThis);
