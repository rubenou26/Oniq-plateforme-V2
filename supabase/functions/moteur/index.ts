// ═══════════════════════════════════════════════════════════════════
// ONIQ PILOTAGE — le moteur d'envoi
//
// Appelé toutes les cinq minutes par la minuterie de la base. Deux
// temps, volontairement séparés :
//   1. FABRIQUER — parcourir les règles actives, regarder ce qui s'est
//      passé dans le CRM, et poser dans la file ce qui doit partir.
//   2. EXPÉDIER  — prendre ce qui est dû, vérifier l'opposition et les
//      heures, envoyer, marquer.
// Les séparer permet de voir ce qui va partir avant que ça parte, et
// d'annuler. Un moteur qui fabrique et envoie d'un seul geste ne se
// contrôle pas.
//
// Aucune clé n'est écrite ici : elles arrivent par les secrets du
// projet (Edge Functions → Secrets).
// ═══════════════════════════════════════════════════════════════════

const URL_BASE = Deno.env.get("SUPABASE_URL")!;
const CLE_SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// La clé anonyme sert à une seule chose : demander à la base, avec le
// jeton de l'appelant, s'il fait partie de l'équipe. C'est la base qui
// répond, pas nous.
const CLE_ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const BREVO = Deno.env.get("BREVO_API_KEY") ?? "";
// Deux maisons peuvent partager un compte d'envoi, ou en avoir chacune
// le sien. Une cle par maison si elle existe, sinon la cle commune :
// on ne se ferme aucune des deux portes.
const BREVO_MAISON: Record<string, string> = {
  bornistes: Deno.env.get("BREVO_API_KEY_BORNISTES") ?? "",
  tiimizy: Deno.env.get("BREVO_API_KEY_TIIMIZY") ?? "",
};
function cleBrevo(activite: string): string {
  return BREVO_MAISON[activite] || BREVO;
}

const H = {
  apikey: CLE_SERVICE,
  Authorization: `Bearer ${CLE_SERVICE}`,
  "Content-Type": "application/json",
};

async function lire(table: string, q: string) {
  const r = await fetch(`${URL_BASE}/rest/v1/${table}?${q}`, { headers: H });
  if (!r.ok) throw new Error(`${table} ${r.status} ${await r.text()}`);
  return await r.json();
}
async function ecrire(table: string, corps: unknown, prefer = "return=minimal") {
  const r = await fetch(`${URL_BASE}/rest/v1/${table}`, {
    method: "POST",
    headers: { ...H, Prefer: `${prefer},resolution=ignore-duplicates` },
    body: JSON.stringify(corps),
  });
  if (!r.ok && r.status !== 409) throw new Error(`${table} ${r.status} ${await r.text()}`);
  return r.status === 409 ? [] : await r.json().catch(() => []);
}
async function majr(table: string, filtre: string, corps: unknown) {
  const r = await fetch(`${URL_BASE}/rest/v1/${table}?${filtre}`, {
    method: "PATCH", headers: H, body: JSON.stringify(corps),
  });
  // Une mise à jour refusée en silence, c'est un message marqué
  // « envoyé » qui ne l'est pas — ou l'inverse. On veut le savoir.
  if (!r.ok) throw new Error(`${table} ${r.status} ${await r.text()}`);
  await r.text().catch(() => "");
}

// Un service externe qui ne répond pas ne doit pas geler le moteur
// jusqu'à ce que Supabase le coupe : quinze secondes, puis on passe.
function delai(ms = 15000): { signal: AbortSignal; fin: () => void } {
  const stop = new AbortController();
  const minuteur = setTimeout(() => stop.abort(), ms);
  return { signal: stop.signal, fin: () => clearTimeout(minuteur) };
}

// Les valeurs qu'on glisse dans un filtre PostgREST viennent de la base,
// mais une virgule ou une parenthèse dans un nom de société suffisait
// à casser la requête. Un identifiant ne passe que s'il a la forme
// d'un uuid ; un texte est cité et échappé selon la syntaxe de
// PostgREST, puis encodé pour l'URL.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function listeIds(l: unknown[]): string {
  return l.map((x) => String(x ?? "")).filter((x) => UUID.test(x)).join(",");
}
function listeTextes(l: unknown[]): string {
  return l.map((x) => encodeURIComponent(
    `"${String(x ?? "").replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`)).join(",");
}

// Qui appelle ? Soit la minuterie de la base, qui porte la clé service
// (elle ne quitte jamais Supabase) ; soit une personne de l'équipe,
// dont on fait vérifier le jeton par la base elle-même. Tout autre
// appelant est renvoyé : un moteur d'envoi ouvert à tous est un
// canon à SMS.
async function appelantAutorise(req: Request): Promise<boolean> {
  const jeton = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!jeton) return false;
  if (jeton === CLE_SERVICE) return true;
  // La clé en mémoire peut dater d'un déploiement antérieur à une
  // régénération. Plutôt que de refuser sur une simple comparaison, on
  // laisse la base juger : un jeton qui lit les réglages est soit la
  // clé service, soit un compte de direction. Les deux ont le droit.
  try {
    const d0 = delai();
    const r0 = await fetch(`${URL_BASE}/rest/v1/ls_reglages?select=cle&limit=1`, {
      headers: { apikey: jeton, Authorization: `Bearer ${jeton}` }, signal: d0.signal,
    }).finally(d0.fin);
    if (r0.ok) {
      const l0 = await r0.json().catch(() => []);
      if (Array.isArray(l0) && l0.length) return true;
    } else await r0.text().catch(() => "");
  } catch { /* on passe à la vérification suivante */ }
  if (!CLE_ANON) return false;
  const d = delai();
  try {
    const r = await fetch(`${URL_BASE}/rest/v1/rpc/ls_est_staff`, {
      method: "POST",
      headers: { apikey: CLE_ANON, Authorization: `Bearer ${jeton}`, "Content-Type": "application/json" },
      body: "{}",
      signal: d.signal,
    });
    if (!r.ok) { await r.text().catch(() => ""); return false; }
    return (await r.json()) === true;
  } catch { return false; }
  finally { d.fin(); }
}

// ── Les réglages, lus une fois par passage ────────────────────────
type Reglages = Record<string, string>;

// Deux maisons, deux identités. Une clé vide pour une maison veut dire
// « prends celle du dessus » : on ne duplique que ce qui diffère.
// prenom@oniq.online sur un domaine d'envoi mail.oniq.online donne
// prenom@mail.oniq.online : chacun écrit de son adresse, sur le
// domaine qui est authentifié.
function adresseSur(mailPersonne: string, adresseMaison: string): string {
  const local = String(mailPersonne || "").split("@")[0];
  const domaine = String(adresseMaison || "").split("@")[1] || "";
  return local && domaine ? `${local}@${domaine}` : "";
}

// L'identifiant d'une personne, c'est la partie avant le @ de son
// adresse PROFESSIONNELLE (colonne repondre_a de ls_equipe), pas celle
// de son compte de connexion : quelqu'un peut se connecter avec un
// Gmail sans qu'un client le voie jamais. Le domaine, lui, vient de la
// maison du destinataire. Meme regle que dans la page, mot pour mot.
// Depuis v3k, une adresse peut etre ecrite noir sur blanc sur la fiche
// du commercial, une par maison (mail_bornistes, mail_tiimizy). Elle
// passe avant toute deduction : le jour ou les deux adresses d'une
// personne n'ont pas le meme identifiant, la deduction se trompait en
// silence et le client recevait un message d'une boite inexistante.
function identiteEnvoi(eq: any, proprio: string, rm: Reglages, activite: string) {
  const m = (activite === "tiimizy" || activite === "bornistes") ? activite : "";
  const sienne = m ? String(eq?.[`mail_${m}`] ?? "").trim() : "";
  const pro = String(eq?.repondre_a ?? "").trim();
  const base = sienne || pro || proprio;
  const mail = sienne
    || String(eq?.envoi_email ?? "").trim()
    || adresseSur(base, rm.expediteur_email);
  const rep = sienne || adresseSur(base, rm.repondre_a || "") || pro || rm.repondre_a || proprio;
  const nom = String(eq?.envoi_nom ?? "").trim()
    || (eq?.nom ? `${eq.nom}${rm.expediteur_nom ? " — " + rm.expediteur_nom : ""}` : "");
  return { mail, rep, nom };
}

function pourMaison(r: Reglages, activite: string): Reglages {
  const m = (activite === "tiimizy" || activite === "bornistes") ? activite : "";
  if (!m) return r;
  const o: Reglages = { ...r };
  for (const c of ["expediteur_nom", "expediteur_email", "repondre_a", "sms_expediteur"]) {
    const v = r[`${c}_${m}`];
    if (v && v.trim()) o[c] = v.trim();
  }
  return o;
}
async function reglages(): Promise<Reglages> {
  const l = await lire("ls_reglages", "select=cle,valeur");
  const o: Reglages = {};
  for (const r of l) o[r.cle] = r.valeur;
  return o;
}

// ── Le remplissage des repères ────────────────────────────────────
// Le registre écrit « URBAN 5 (URBAN 5) », « LA RAVOIRE », « SAIDOUN
// SALIM ». Recopié tel quel dans un mail, ça donne « Je ne sais pas où
// en est URBAN 5 (URBAN 5) sur ce sujet », et le lecteur comprend en
// trois lignes qu'aucune main humaine n'est passée par là.
//
// On ne corrige que ce qui est manifestement du fichier : un nom
// entièrement en capitales, ou une enseigne répétée entre parenthèses.
// Un nom déjà écrit normalement n'est jamais touché.
const PETITS_MOTS = ["de","du","des","la","le","les","et","à","au","aux","en","sur","sous","d","l"];
function jolieCasse(t: unknown): string {
  const s = String(t ?? "").trim();
  if (!s) return "";
  if (/[a-zà-ÿ]/.test(s)) return s;          // déjà en casse mélangée
  return s.toLowerCase().split(/(\s+|-|’|')/).map((m, i) => {
    if (!/[a-zà-ÿ0-9]/i.test(m)) return m;
    if (/^[bcdfghjklmnpqrstvwxz]{2,5}$/i.test(m)) return m.toUpperCase();  // un sigle reste un sigle
    if (i > 0 && PETITS_MOTS.includes(m)) return m;
    return m.charAt(0).toUpperCase() + m.slice(1);
  }).join("");
}
function nomPropre(t: unknown): string {
  let s = String(t ?? "").trim().replace(/\s+/g, " ");
  if (!s) return "";
  s = s.replace(/^(.*?)\s*\(\s*\1\s*\)$/i, "$1");                       // « X (X) »
  s = s.replace(/[\s,]+(SAS|SASU|SARL|EURL|SNC|SCI|SCM|EI|EIRL)\.?$/i, ""); // la forme juridique
  return jolieCasse(s);
}

// Un montant écrit « 12964 » dans un mail de relance fait amateur, et
// fait douter du devis lui-même. On l'écrit comme on l'écrirait à la
// main : espaces insécables entre les milliers, et « € HT ».
function joliMontant(v: unknown): string {
  const n = Number(v);
  if (!isFinite(n) || !n) return "";
  return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, "\u202f") + "\u00a0€ HT";
}
// « 2026-12-01 » devient « décembre ». Un client qui lit le mois qu'il
// a lui-même annoncé sait qu'on l'a écouté.
const MOIS_FR = ["janvier","février","mars","avril","mai","juin","juillet","août",
  "septembre","octobre","novembre","décembre"];
function moisLisible(v: unknown): string {
  const m = /^(\d{4})-(\d{2})/.exec(String(v ?? ""));
  if (!m) return "";
  return `${MOIS_FR[Number(m[2]) - 1] ?? ""} ${m[1]}`;
}
// Écrire à contact@ sans dire à qui, c'est écrire à personne. La
// mention se met en tête, comme sur une enveloppe, et seulement quand
// l'adresse est un standard : à une adresse nominative elle ferait
// bizarre.
function enTeteAttention(email: string, dirigeant: string): string {
  const nom = jolieCasse(String(dirigeant ?? "")).trim();
  if (!nom || !estGenerique(String(email ?? ""))) return "";
  return `À l'attention de ${nom}\n\n`;
}
function remplir(t: string, d: Record<string, unknown>) {
  return String(t ?? "").replace(/\{(\w+)\}/g, (_, k) => {
    const v = d[k];
    if (k === "societe") return nomPropre(v);
    if (k === "dirigeant" || k === "ville") return jolieCasse(v);
    if (k === "montant") return joliMontant(v);
    return String(v ?? "");
  });
}

// ── Les heures d'envoi ────────────────────────────────────────────
// Un SMS à 22 h ou un dimanche ne fait pas gagner du temps, il fait
// perdre un prospect.
function heureOuvrable(r: Reglages, quand = new Date()) {
  const p = new Intl.DateTimeFormat("fr-FR", {
    timeZone: "Europe/Paris", hour: "2-digit", weekday: "short", hour12: false,
  }).formatToParts(quand);
  const h = Number(p.find((x) => x.type === "hour")?.value ?? "12");
  const j = p.find((x) => x.type === "weekday")?.value ?? "lun";
  const debut = Number(r.heure_debut ?? "9");
  const fin = Number(r.heure_fin ?? "18");
  const ouvres = (r.jours_ouvres ?? "oui") === "oui";
  if (ouvres && (j.startsWith("sam") || j.startsWith("dim"))) return false;
  return h >= debut && h < fin;
}

// ═══════════════════════════════════════════════════════════════════
// 1. FABRIQUER
// ═══════════════════════════════════════════════════════════════════
type Membre = { email: string; nom?: string; envoi_nom?: string;
                envoi_email?: string; repondre_a?: string };

async function fabriquer(r: Reglages) {
  // L'équipe, lue une seule fois : c'est elle qui donne le prénom et
  // l'adresse de chaque expéditeur.
  const equipe = new Map<string, Membre>();
  try {
    const membres = await lire("ls_equipe",
      "select=email,nom,envoi_nom,envoi_email,repondre_a,mail_bornistes,mail_tiimizy&limit=200");
    for (const m of membres) equipe.set(String(m.email).toLowerCase(), m);
  } catch { /* l'envoi retombera sur l'adresse de la maison */ }
  const regles = await lire("ls_regles", "select=*&actif=is.true");
  const maintenant = Date.now();
  let posees = 0;
  const detail: string[] = [];

  // Chaque règle est traitée à part : une règle qui échoue (filtre
  // refusé, table absente) se note dans le journal et ne retient pas
  // les autres, ni l'expédition de ce qui est déjà en file.
  for (const g of regles) {
    try {
      await uneRegle(g, r, equipe, maintenant, detail, (n) => { posees += n; });
    } catch (err) {
      detail.push(`${g.nom} : ERREUR ${String((err as Error).message ?? err).slice(0, 160)}`);
    }
  }
  return { posees, detail };
}

async function uneRegle(g: any, r: Reglages, equipe: Map<string, Membre>, maintenant: number,
                        detail: string[], compte: (n: number) => void) {
  const filtreAct = g.activite === "les_deux" ? "" : `&activite=eq.${encodeURIComponent(String(g.activite))}`;
  let cibles: any[] = [];
  type Sortie = { dest: string; cle: string; quand: Date; d: Record<string, unknown>;
                  prospect_id?: string | null; partenaire_id?: string | null };
  let facon: (x: any) => Sortie | null = () => null;
  const champ = (x: any) => (g.canal === "sms" ? x.tel : x.email);

  if (g.declencheur === "lead_recu") {
    // Une fiche créée depuis une source de leads, encore jamais
    // appelée. est_lead écarte les fiches importées du registre ou
    // saisies à la main : elles n'ont rien demandé, un accusé de
    // réception les surprendrait.
    const depuis = new Date(maintenant - 24 * 3600e3).toISOString();
    cibles = await lire("ls_prospects",
      `select=*&created_at=gte.${depuis}&appel_resultat=is.null&est_lead=is.true` + filtreAct);
    facon = (x) => champ(x)
      ? { dest: champ(x), cle: `${g.id}:${x.id}`, prospect_id: x.id,
          quand: new Date(new Date(x.created_at).getTime() + g.delai_min * 60e3), d: x }
      : null;

  } else if (g.declencheur === "appel_interesse") {
    const depuis = new Date(maintenant - 7 * 24 * 3600e3).toISOString();
    cibles = await lire("ls_prospects",
      `select=*&appel_resultat=eq.interesse&updated_at=gte.${depuis}` + filtreAct);
    facon = (x) => champ(x)
      ? { dest: champ(x), cle: `${g.id}:${x.id}`, prospect_id: x.id,
          quand: new Date(new Date(x.updated_at).getTime() + g.delai_min * 60e3), d: x }
      : null;

  } else if (g.declencheur === "devis_sans_reponse") {
    const devis = await lire("ls_devis", `select=*&statut=in.(envoye,relance)` + filtreAct);
    const ids = listeIds(devis.map((d: any) => d.prospect_id));
    const pros = ids
      ? await lire("ls_prospects", `select=*&id=in.(${ids})`) : [];
    const parId: Record<string, any> = {};
    for (const p of pros) parId[p.id] = p;
    cibles = devis.map((d: any) => ({ ...d, __p: parId[d.prospect_id] }));
    facon = (x) => {
      const p = x.__p ?? {};
      const dest = g.canal === "sms" ? p.tel : p.email;
      if (!dest || !x.envoye_le) return null;
      // Un mois annoncé arrête les relances d'insistance : quand le
      // client a dit « ce sera pour décembre », lui redemander deux
      // fois en quinze jours ne fait que l'agacer. Seule la première,
      // celle qui vérifie que le devis est bien arrivé, part quand
      // même. La reprise se fera au mois d'avant, par sa propre règle.
      const ech = p.echeance_le ? new Date(`${String(p.echeance_le).slice(0, 10)}T00:00:00Z`).getTime() : 0;
      if (ech && g.delai_min > 7200 && ech - maintenant > 45 * 864e5) return null;
      return { dest, cle: `${g.id}:${x.id}`, prospect_id: p.id ?? null,
        quand: new Date(new Date(x.envoye_le).getTime() + g.delai_min * 60e3),
        d: { ...p, societe: x.societe, montant: x.montant_ht } };
    };

  } else if (g.declencheur === "echeance_proche") {
    // Le mois annoncé approche. On reprend contact avant que le client
    // ne rappelle celui qui l'a relancé entre-temps, et on cite le mois
    // qu'il a donné : c'est la preuve qu'on l'a écouté.
    const d1 = new Date(maintenant + 20 * 864e5).toISOString().slice(0, 10);
    const d2 = new Date(maintenant + 45 * 864e5).toISOString().slice(0, 10);
    cibles = await lire("ls_prospects",
      `select=*&echeance_le=gte.${d1}&echeance_le=lte.${d2}&etape=not.in.(Gagne,Perdu)` + filtreAct);
    facon = (x) => champ(x)
      ? { dest: champ(x), cle: `${g.id}:${x.id}:${String(x.echeance_le).slice(0, 7)}`,
          prospect_id: x.id, quand: new Date(maintenant),
          d: { ...x, mois: moisLisible(x.echeance_le) } }
      : null;

  } else if (g.declencheur === "rappel_demain") {
    const d1 = new Date(maintenant + 20 * 3600e3).toISOString();
    const d2 = new Date(maintenant + 32 * 3600e3).toISOString();
    cibles = await lire("ls_prospects",
      `select=*&rappel_le=gte.${d1}&rappel_le=lte.${d2}` + filtreAct);
    facon = (x) => champ(x)
      ? { dest: champ(x), cle: `${g.id}:${x.id}:${String(x.rappel_le).slice(0, 10)}`,
          prospect_id: x.id, quand: new Date(maintenant), d: x }
      : null;

  } else if (g.declencheur === "commission_validee") {
    const comms = await lire("ls_commissions", "select=*&statut=eq.validee");
    const pids = listeIds([...new Set(comms.map((c: any) => c.partenaire_id))]);
    const parts = pids
      ? await lire("ls_prescripteurs", `select=*&id=in.(${pids})`) : [];
    const parId: Record<string, any> = {};
    for (const p of parts) parId[p.id] = p;
    cibles = comms.map((c: any) => ({ ...c, __p: parId[c.partenaire_id] }));
    facon = (x) => {
      const p = x.__p ?? {};
      const dest = g.canal === "sms" ? p.tel : (p.compte_email || p.email);
      if (!dest) return null;
      return { dest, cle: `${g.id}:${x.id}`, quand: new Date(maintenant),
        partenaire_id: p.id ?? null,
        d: { dirigeant: p.contact || p.nom, societe: p.nom, montant: x.montant } };
    };

  } else if (g.declencheur === "renouvellement") {
    const j60 = new Date(maintenant + 60 * 24 * 3600e3).toISOString().slice(0, 10);
    const j55 = new Date(maintenant + 55 * 24 * 3600e3).toISOString().slice(0, 10);
    cibles = await lire("ls_abonnements",
      `select=*&statut=eq.actif&renouvellement_le=lte.${j60}&renouvellement_le=gte.${j55}`);
    // L'adresse vit sur la fiche compte : on la retrouve par le nom.
    const socs = listeTextes(cibles.map((a: any) => a.societe).filter(Boolean));
    const pros = socs
      ? await lire("ls_prospects", `select=*&societe=in.(${socs})`) : [];
    const parSoc: Record<string, any> = {};
    for (const p of pros) parSoc[p.societe] = p;
    facon = (x) => {
      const p = parSoc[x.societe] ?? {};
      const dest = g.canal === "sms" ? p.tel : p.email;
      if (!dest) return null;
      return { dest, cle: `${g.id}:${x.id}:${x.renouvellement_le}`, prospect_id: p.id ?? null,
        quand: new Date(maintenant), d: { ...p, societe: x.societe } };
    };
  }

  let n = 0;
  for (const x of cibles) {
    const f = facon(x);
    if (!f) continue;
    // Les conditions de taille et de chiffre d'affaires, quand elles existent.
    if (g.eff_min && Number(x.effectif_num ?? x.__p?.effectif_num ?? 0) < g.eff_min) continue;
    if (g.ca_min && Number(x.ca ?? x.__p?.ca ?? 0) < g.ca_min) continue;

    // Le message part au nom du commercial à qui la fiche appartient.
    // Un accusé de réception signé « contact@ » oblige le client à
    // chercher qui l'a appelé ; signé du bon prénom, il peut répondre.
    const act = String(x.activite ?? g.activite);
    const rm = pourMaison(r, act);
    const proprio = String(x.owner_email ?? x.__p?.owner_email ?? "").trim();
    const eq = proprio ? equipe.get(proprio.toLowerCase()) : null;
    const idn = identiteEnvoi(eq, proprio, rm, act);
    const expNom = idn.nom, expMail = idn.mail, rep = idn.rep;

    const d = { ...f.d, expediteur: (eq?.nom || rm.expediteur_nom) ?? "" };
    const ligne = {
      cle: f.cle,
      canal: g.canal,
      destinataire: String(f.dest).trim(),
      objet: remplir(g.objet, d),
      corps: remplir(g.corps, d),
      regle_id: g.id,
      prospect_id: f.prospect_id ?? null,
      partenaire_id: f.partenaire_id ?? null,
      societe: String(x.societe ?? x.__p?.societe ?? ""),
      activite: act,
      expediteur_nom: expNom,
      expediteur_email: expMail,
      repondre_a: rep,
      owner_email: proprio,
      statut: "en_attente",
      a_envoyer_le: f.quand.toISOString(),
    };
    await ecrire("ls_envois", ligne);
    n++;
  }
  compte(n);
  if (n) detail.push(`${g.nom} : ${n}`);
  await majr("ls_regles", `id=eq.${encodeURIComponent(String(g.id))}`,
    { dernier_run: new Date().toISOString() });
}

// ═══════════════════════════════════════════════════════════════════
// 2. EXPÉDIER
// ═══════════════════════════════════════════════════════════════════
// Un message porte le nom de celui qui l'envoie. Si la ligne de la
// file en porte un, il gagne : le client doit pouvoir répondre au
// commercial qui l'a eu au téléphone, pas à une adresse de service.
function expediteurDe(r: Reglages, e: any) {
  const email = String(e.expediteur_email || "").trim() || r.expediteur_email;
  const nom = String(e.expediteur_nom || "").trim() || r.expediteur_nom || "ONIQ";
  const rep = String(e.repondre_a || "").trim() || r.repondre_a || "";
  return { email, nom, rep };
}

async function envoyerEmail(r: Reglages, e: any) {
  const cle = cleBrevo(String(e.activite || ""));
  if (!cle) throw new Error("Clé d'envoi absente (secret BREVO_API_KEY)");
  const exp = expediteurDe(r, e);
  const pied = r.pied_email ? `\n\n—\n${r.pied_email}` : "";
  const d = delai();
  const rep = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: { "api-key": cle, "Content-Type": "application/json", accept: "application/json" },
    signal: d.signal,
    body: JSON.stringify({
      sender: { name: exp.nom, email: exp.email },
      to: [{ email: e.destinataire }],
      // Le corps habillé quand la page en a produit un ; sinon le
      // texte seul, qui reste lisible partout.
      ...(e.corps_html ? { htmlContent: String(e.corps_html) } : {}),
      // Les pièces jointes voyagent par leur adresse, jamais en
      // base 64 : la file d'envoi doit rester légère.
      ...(Array.isArray(e.pieces) && e.pieces.length
        ? { attachment: e.pieces
              .filter((x: any) => x && x.url)
              .map((x: any) => ({ url: String(x.url), name: String(x.nom || "document.pdf") })) }
        : {}),
      // L'adresse qui signe n'est pas celle qui reçoit : un sous-domaine
      // d'envoi n'a pas de boîte aux lettres. Sans replyTo, la réponse
      // du client — y compris un « STOP » — rebondit dans le vide.
      ...(exp.rep ? { replyTo: { email: exp.rep } } : {}),
      subject: e.objet || "(sans objet)",
      textContent: e.corps + pied,
      // Les étiquettes reviennent telles quelles dans les retours de
      // Brevo : c'est ainsi qu'un rebond retrouve sa ligne et sa boîte.
      tags: [`envoi:${e.id}`, ...(e.campagne_id ? [`camp:${e.campagne_id}`] : []),
             ...(e.boite_id ? [`boite:${e.boite_id}`] : [])],
    }),
  }).finally(d.fin);
  if (!rep.ok) throw new Error(`Brevo e-mail ${rep.status} ${await rep.text()}`);
  const j = await rep.json().catch(() => ({}));
  return String((j as any)?.messageId ?? "");
}

// ── Les campagnes : la fenêtre, les boîtes, le rythme ──────────────
// Une campagne froide ne part que du lundi au vendredi, de 8 h 30 à
// 12 h et de 14 h à 18 h, heure de Paris. Rien le soir, même si la
// file déborde : ce qui attend attendra.
//
// Le samedi dépend de la cible, et d'elle seule. Un artisan, un
// conducteur de travaux, un commerçant sont à leur poste le samedi
// matin : pour eux c'est un bon créneau. Un cabinet
// comptable, un syndic, un bureau d'études sont fermés, et le mail
// dort jusqu'à lundi 9 h dans une pile qu'on vide sans lire. La
// campagne porte donc son propre réglage. Le dimanche, jamais : c'est
// le jour où l'on se fait signaler comme indésirable.
function fenetreCampagne(quand = new Date(), samedi = false): boolean {
  const p = new Intl.DateTimeFormat("fr-FR", {
    timeZone: "Europe/Paris", hour: "2-digit", minute: "2-digit", weekday: "short", hour12: false,
  }).formatToParts(quand);
  const h = Number(p.find((x) => x.type === "hour")?.value ?? "0");
  const m = Number(p.find((x) => x.type === "minute")?.value ?? "0");
  const j = p.find((x) => x.type === "weekday")?.value ?? "lun";
  const t = h * 60 + m;
  if (j.startsWith("dim")) return false;
  if (j.startsWith("sam")) return samedi && t >= 9 * 60 && t < 12 * 60;
  return (t >= 8 * 60 + 30 && t < 12 * 60) || (t >= 14 * 60 && t < 18 * 60);
}

// Le plafond du jour d'une boîte, la même règle que ls_boite_plafond
// dans la base : 15, 25, 40, puis 50, jamais plus.
function plafondBoite(depuis: string): number {
  const d = new Date(String(depuis || "").slice(0, 10) + "T00:00:00Z").getTime();
  const jours = Math.floor((Date.now() - d) / 864e5);
  return jours < 3 ? 15 : jours < 7 ? 25 : jours < 14 ? 40 : 50;
}

function minuitParis(): string {
  const now = new Date();
  const jour = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris",
    year: "numeric", month: "2-digit", day: "2-digit" }).format(now);   // 2026-09-08
  const aParis = new Date(now.toLocaleString("en-US", { timeZone: "Europe/Paris" })).getTime();
  const enUtc = new Date(now.toLocaleString("en-US", { timeZone: "UTC" })).getTime();
  return new Date(new Date(jour + "T00:00:00Z").getTime() - (aParis - enUtc)).toISOString();
}

// L'habillage d'un mail de campagne, mot pour mot ce que fait la page.
// Un contact ne doit pas recevoir un mail 1 habillé et un mail 2 nu :
// c'est la même personne qui écrit, ça doit se voir.
function echHtml(t: string): string {
  return String(t ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
// La charte d'ONIQ : nuit #08090C, accent #2B5FD9 (rangé dans « vert »,
// le nom historique de la propriété), gris #586274, filet #E5E8ED. Les
// clés bornistes / tiimizy sont les deux maisons : ONIQ Sur mesure et
// ONIQ Logiciels. La page porte la même charte : les deux doivent
// rester d'accord, un contact reçoit des mails des deux côtés.
const CHARTE: Record<string, Record<string, string>> = {
  bornistes: { nuit: "#08090C", vert: "#2B5FD9", gris: "#586274", filet: "#E5E8ED",
    nom: "ONIQ", baseline: "Logiciels et applications sur mesure",
    adresse: "Marsanne (26)", site: "oniq.online",
    preuves: "Code livré et documenté · Prix ferme · Maquette offerte" },
  tiimizy: { nuit: "#08090C", vert: "#2B5FD9", gris: "#586274", filet: "#E5E8ED",
    nom: "ONIQ", baseline: "Logiciels métier pour les PME",
    adresse: "Marsanne (26)", site: "oniq.online",
    preuves: "BatiManager · OniMetri · OniPilote · OniPromail · OniBoost" },
};
// Segoe UI d'abord, comme sur les mails de devis : c'est la police de
// la maison, elle ne se télécharge pas, et sur Mac la pile descend sur
// San Francisco sans que personne ne le remarque.
const POL = "'Segoe UI',-apple-system,BlinkMacSystemFont,Roboto,Helvetica,Arial,sans-serif";

function paragraphesSimples(corps: string): string {
  return String(corps ?? "").split(/\n{2,}/).map((p) =>
    `<p style="margin:0 0 14px">${echHtml(p).replace(/\n/g, "<br>")}</p>`).join("");
}
function htmlSobre(corps: string, pied: string): string {
  return `<!DOCTYPE html><html lang="fr"><head><meta charset="utf-8"></head>`
    + `<body style="margin:0;padding:18px 16px;background:#ffffff">`
    + `<div style="max-width:620px;font-family:${POL};`
    + `font-size:15px;line-height:1.6;color:#1a1a1a">${paragraphesSimples(corps)}`
    + (pied ? `<p style="margin:22px 0 0;font-size:12px;color:#6b7280">${echHtml(pied)}</p>` : "")
    + `</div></body></html>`;
}
// La signature maison : le filet d'accent, le nom, la fonction, le numéro
// cliquable, les preuves et l'adresse. Aucune image à charger.
function htmlMaison(corps: string, sig: { nom?: string; fonction?: string; tel?: string },
                    activite: string, pied: string): string {
  const c = CHARTE[activite] ?? CHARTE.bornistes;
  const tel = sig?.tel ? String(sig.tel).replace(/[^0-9+]/g, "").replace(/^0/, "+33") : "";
  return `<!DOCTYPE html><html lang="fr"><head><meta charset="utf-8">`
    + `<meta name="viewport" content="width=device-width,initial-scale=1"></head>`
    + `<body style="margin:0;padding:20px 16px;background:#ffffff">`
    + `<div style="max-width:620px;font-family:${POL};font-size:15px;line-height:1.6;color:#1a1a1a">`
    + paragraphesSimples(corps)
    + `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:22px">`
      + `<tr><td style="border-top:2px solid ${c.vert};padding-top:12px;font-family:${POL}">`
      + (sig?.nom ? `<div style="font-size:14px;font-weight:700;color:${c.nuit}">${echHtml(sig.nom)}</div>` : "")
      + `<div style="font-size:12.5px;color:${c.gris};margin-top:2px">`
        + (sig?.fonction ? `${echHtml(sig.fonction)}, ` : "")
        + `<span style="color:${c.nuit};font-weight:600">${echHtml(c.nom)}</span></div>`
      + (c.baseline ? `<div style="font-size:11.5px;color:${c.gris};margin-top:1px">${echHtml(c.baseline)}</div>` : "")
      + (tel ? `<div style="font-size:12.5px;margin-top:6px"><a href="tel:${echHtml(tel)}" `
        + `style="color:${c.vert};font-weight:600;text-decoration:none">${echHtml(String(sig.tel))}</a></div>` : "")
      + `</td></tr></table>`
    + `<div style="margin-top:16px;border-top:1px solid ${c.filet};padding-top:10px;`
      + `font-size:11px;line-height:1.7;color:${c.gris}">`
      + [c.adresse, c.site].filter(Boolean).map(echHtml).join("&nbsp;&nbsp;·&nbsp;&nbsp;")
      + (c.preuves ? `<br>${echHtml(c.preuves)}` : "")
      + (pied ? `<br>${echHtml(pied)}` : "")
    + `</div></div></body></html>`;
}
// La charte complète : le bandeau et la carte des mails de devis. La
// page prévient que c'est risqué en prospection froide ; si le
// commercial l'a choisi en connaissance de cause, on le respecte.
function htmlCharte(corps: string, sig: { nom?: string; fonction?: string; tel?: string },
                    activite: string, pied: string): string {
  const c = CHARTE[activite] ?? CHARTE.bornistes;
  const tel = sig?.tel ? String(sig.tel).replace(/[^0-9+]/g, "").replace(/^0/, "+33") : "";
  return `<!DOCTYPE html><html lang="fr"><head><meta charset="utf-8">`
    + `<meta name="viewport" content="width=device-width,initial-scale=1"></head>`
    + `<body style="margin:0;padding:0;background:#f5f6f8">`
    + `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" `
      + `style="background:#f5f6f8;padding:28px 16px"><tr><td align="center">`
    + `<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" `
      + `style="width:600px;max-width:100%;background-color:#ffffff;border:1px solid ${c.filet};`
      + `border-radius:14px;overflow:hidden;font-family:${POL};color:${c.nuit}">`
    + `<tr><td style="background-color:${c.nuit};padding:24px 32px 20px">`
      + `<div style="font-size:13px;font-weight:700;letter-spacing:3.5px;color:#ffffff;`
      + `text-transform:uppercase;line-height:1.3">`
      + echHtml(c.nom).toUpperCase().replace(/ /g, "&nbsp;") + `</div>`
      + (c.baseline ? `<div style="font-size:10px;font-weight:600;letter-spacing:2px;color:${c.vert};`
        + `text-transform:uppercase;margin-top:6px">${echHtml(c.baseline)}</div>` : "")
    + `</td></tr>`
    + `<tr><td style="height:3px;background-color:${c.vert};font-size:0;line-height:0">&nbsp;</td></tr>`
    + `<tr><td style="padding:30px 32px 4px;font-size:15px;line-height:1.65;color:${c.nuit}">`
      + paragraphesSimples(corps) + `</td></tr>`
    + `<tr><td style="padding:6px 32px 0;font-size:15px;line-height:1.65;color:${c.nuit}">`
      + (sig?.nom ? `<p style="margin:0 0 3px;font-weight:600;color:${c.nuit}">${echHtml(sig.nom)}</p>` : "")
      + (sig?.fonction ? `<p style="margin:0 0 2px;font-size:12px;color:${c.gris}">`
        + `${echHtml(sig.fonction)}, ${echHtml(c.nom)}</p>` : "")
      + (tel ? `<p style="margin:0 0 24px;font-size:12px"><a href="tel:${echHtml(tel)}" `
        + `style="color:${c.vert};font-weight:600;text-decoration:none">${echHtml(String(sig.tel))}</a></p>`
        : `<div style="height:22px"></div>`)
    + `</td></tr>`
    + `<tr><td style="padding:0 32px 26px">`
      + `<div style="height:1px;background-color:${c.filet};font-size:0;line-height:0">&nbsp;</div>`
      + `<div style="margin-top:14px;font-size:11px;line-height:1.75;color:${c.gris}">`
      + (c.adresse ? `${echHtml(c.adresse)}<br>` : "")
      + (c.preuves ? `${echHtml(c.preuves)}&nbsp;&nbsp;·&nbsp;&nbsp;` : "")
      + echHtml(c.site) + (pied ? `<br>${echHtml(pied)}` : "")
      + `</div></td></tr>`
    + `</table></td></tr></table></body></html>`;
}
function mailCampagne(corps: string, sig: { nom?: string; fonction?: string; tel?: string },
                      activite: string, habillage: string, pied: string): string {
  if (habillage === "charte") return htmlCharte(corps, sig, activite, pied);
  if (habillage === "sobre") return htmlSobre(corps, pied);
  return htmlMaison(corps, sig, activite, pied);
}
// La signature d'une campagne est rangée en texte sur la fiche. Pour
// l'habillage, on en retire les trois éléments qui se dessinent.
function signatureLue(t: string): { nom?: string; fonction?: string; tel?: string } {
  const l = String(t ?? "").split(/\n/).map((x) => x.trim()).filter(Boolean);
  const tel = l.find((x) => /^[+0][0-9 .()-]{8,}$/.test(x)) ?? "";
  const fonction = (l[1] ?? "").replace(/,\s*[^,]*$/, "");
  return { nom: l[0] ?? "", fonction, tel };
}

type Boite = { id: string; adresse: string; adresse_envoi: string; nom_expediteur: string; actif: boolean;
               mise_en_service_le: string; plafond: number; jour: number };

async function boitesDuJour(): Promise<Map<string, Boite>> {
  const out = new Map<string, Boite>();
  let l: any[] = [];
  try { l = await lire("ls_boites", "select=id,adresse,adresse_envoi,nom_expediteur,actif,mise_en_service_le&limit=200"); }
  catch { return out; }
  // Minuit à Paris, pas UTC : le compteur du jour est celui du jour ouvré.
  const minuit = minuitParis();
  let comptes: any[] = [];
  try {
    comptes = await lire("ls_envois",
      `select=boite_id&statut=eq.envoye&boite_id=not.is.null&envoye_le=gte.${minuit}&limit=5000`);
  } catch { /* on partira de zéro : le plafond de la base fera le reste */ }
  const parBoite = new Map<string, number>();
  for (const c of comptes) parBoite.set(String(c.boite_id), (parBoite.get(String(c.boite_id)) ?? 0) + 1);
  for (const b of l) {
    out.set(String(b.id), { ...b, plafond: plafondBoite(b.mise_en_service_le),
                            jour: parBoite.get(String(b.id)) ?? 0 });
  }
  return out;
}

// Les mails 2 et 3 d'une séquence : posés dans la file quand leur
// heure vient, avec le texte tel qu'il est à ce moment-là dans la
// campagne. Même boîte que le premier mail : le contact voit toujours
// la même personne lui écrire.
async function poserSuites(pied: string): Promise<{ posees: number; detail: string[] }> {
  const detail: string[] = [];
  let posees = 0;
  let dues: any[] = [];
  try {
    dues = await lire("ls_sequences",
      `select=*&statut=eq.en_cours&etape=in.(1,2)&prochain_le=lte.${new Date().toISOString()}&limit=300`);
  } catch (err) {
    return { posees: 0, detail: [`séquences : ${String((err as Error).message ?? err).slice(0, 120)}`] };
  }
  if (!dues.length) return { posees, detail };
  const campagnes = new Map<string, any>();
  const boites = await boitesDuJour();
  for (const s of dues) {
    try {
      const cid = String(s.campagne_id);
      if (!campagnes.has(cid)) {
        const c = await lire("ls_campagnes", `select=*&id=eq.${encodeURIComponent(cid)}&limit=1`);
        campagnes.set(cid, c[0] ?? null);
      }
      const c = campagnes.get(cid);
      if (!c || !["programmee", "en_cours"].includes(String(c.statut))) continue;
      const n = Number(s.etape) + 1;
      const objet = String(c[`objet${n}`] ?? "");
      const corps = String(c[`corps${n}`] ?? "");
      if (!corps.trim()) {
        // Plus de texte à envoyer : la séquence s'achève proprement.
        await majr("ls_sequences", `id=eq.${encodeURIComponent(String(s.id))}`,
          { statut: "termine", sortie: "fin", prochain_le: null, maj_le: new Date().toISOString() });
        continue;
      }
      const b = boites.get(String(s.boite_id)) ?? [...boites.values()].find((x) => x.actif);
      if (!b) { detail.push(`séquence ${s.email} : aucune boîte`); continue; }
      const d = { societe: s.societe ?? "", dirigeant: s.dirigeant ?? "", ville: s.ville ?? "",
                  activite: s.activite ?? "", expediteur: b.nom_expediteur ?? "" };
      const signature = String(c.signature ?? "").trim();
      const hab = String(c.habillage ?? "maison");
      const rempli = enTeteAttention(String(s.email ?? ""), String(s.dirigeant ?? ""))
        + remplir(corps, d);
      // En sobre, la signature s'écrit dans le texte ; ailleurs elle
      // est dessinée, et la répéter ferait double emploi.
      const texte = rempli.trim() + (signature ? "\n\n" + signature : "");
      const ligne = {
        cle: `seq:${s.id}:${n}`,
        canal: "email",
        destinataire: String(s.email).toLowerCase().trim(),
        objet: remplir(objet, d),
        corps: hab === "sobre" ? texte : rempli.trim(),
        corps_html: mailCampagne(rempli, signatureLue(signature), String(s.activite ?? c.activite ?? ""),
                                 hab, String(pied ?? "")),
        prospect_id: s.prospect_id ?? null,
        partenaire_id: s.partenaire_id ?? null,
        societe: String(s.societe ?? ""),
        activite: String(s.activite ?? c.activite ?? ""),
        expediteur_nom: b.nom_expediteur || "",
        expediteur_email: b.adresse_envoi || b.adresse,   // le sous-domaine écrit
        repondre_a: b.adresse,                             // la vraie boîte reçoit
        owner_email: String(c.owner_email ?? ""),
        statut: "en_attente",
        prioritaire: false,
        campagne_id: cid,
        boite_id: b.id,
        sequence_id: s.id,
        etape_seq: n,
        // Un décalage au hasard dans l'heure : deux séquences nées à
        // la même minute ne repartent pas à la même seconde.
        a_envoyer_le: new Date(Date.now() + Math.floor(Math.random() * 3600e3)).toISOString(),
      };
      await ecrire("ls_envois", ligne);
      // La séquence attend maintenant que ce mail parte ; le trigger
      // de la base posera la date du suivant à ce moment-là.
      await majr("ls_sequences", `id=eq.${encodeURIComponent(String(s.id))}`,
        { prochain_le: null, maj_le: new Date().toISOString() });
      posees++;
    } catch (err) {
      detail.push(`séquence ${s.email} : ${String((err as Error).message ?? err).slice(0, 120)}`);
    }
  }
  if (posees) detail.push(`suites de séquence : ${posees}`);
  return { posees, detail };
}
// ── Les notifications push ─────────────────────────────────────────
//
// Le protocole Web Push est chiffré de bout en bout : ni Google ni
// Apple ne peuvent lire le contenu, ils ne font que transporter. La
// bibliothèque web-push s'occupe du chiffrement et de la signature
// VAPID ; on lui donne la clé privée, qui ne quitte jamais les secrets
// de cette fonction.
//
// Un destinataire peut avoir plusieurs appareils : on envoie à tous.
// Et un abonnement expire — le fabricant répond alors 404 ou 410, et
// il faut le retirer, sinon la file se remplit d'échecs éternels.
import webpush from "npm:web-push@3.6.7";

const VAPID_PUB  = Deno.env.get("VAPID_PUBLIC")  ?? "";
const VAPID_PRIV = Deno.env.get("VAPID_PRIVATE") ?? "";
const VAPID_SUJET = Deno.env.get("VAPID_SUJET") ?? "mailto:contact@oniq.online";

async function envoyerPush(e: any) {
  if (!VAPID_PUB || !VAPID_PRIV)
    throw new Error("VAPID_PUBLIC et VAPID_PRIVATE ne sont pas posés dans les secrets.");
  webpush.setVapidDetails(VAPID_SUJET, VAPID_PUB, VAPID_PRIV);

  // Le destinataire d'un push est une personne, pas une adresse : on
  // retrouve ses appareils par son identifiant de partenaire, ou à
  // défaut par son e-mail.
  const filtre = e.partenaire_id && UUID.test(String(e.partenaire_id))
    ? `partenaire_id=eq.${String(e.partenaire_id)}`
    : `email=eq.${encodeURIComponent(String(e.destinataire || ""))}`;
  const cibles = await lire("ls_push", `select=id,endpoint,p256dh,auth&actif=is.true&${filtre}`);
  if (!cibles.length) throw new Error("Aucun appareil abonné pour ce destinataire.");

  const charge = JSON.stringify({
    titre: e.objet || "ONIQ Pilotage",
    corps: String(e.corps || "").slice(0, 240),
    url: "/crm#partenaire",
    tag: e.cle || "oniq",
  });

  let envoyes = 0;
  const erreurs: string[] = [];
  for (const c of cibles) {
    try {
      // La bibliothèque a son propre minuteur, mais on double par une
      // course : un fabricant muet ne doit pas tenir la file.
      const stop = new AbortController();
      const minuteur = setTimeout(() => stop.abort(), 15000);
      await Promise.race([
        webpush.sendNotification(
          { endpoint: c.endpoint, keys: { p256dh: c.p256dh, auth: c.auth } },
          charge, { timeout: 15000 },
        ),
        new Promise((_, refuse) => stop.signal.addEventListener("abort",
          () => refuse(new Error("push : pas de réponse en quinze secondes")))),
      ]).finally(() => clearTimeout(minuteur));
      envoyes++;
    } catch (err) {
      const code = Number((err as any)?.statusCode ?? 0);
      if (code === 404 || code === 410) {
        // L'appareil ne répond plus : désinstallé, cache vidé, ou
        // abonnement révoqué. On le retire au lieu de réessayer.
        await majr("ls_push", `id=eq.${encodeURIComponent(String(c.id))}`, { actif: false })
          .catch(() => {});
      } else {
        erreurs.push(`${code || "?"} ${String((err as Error).message ?? err).slice(0, 80)}`);
      }
    }
  }
  // Un seul appareil joint suffit : la personne est prévenue.
  if (!envoyes) throw new Error(erreurs.join(" · ") || "Tous les appareils ont expiré.");
}

async function envoyerSms(r: Reglages, e: any) {
  const cle = cleBrevo(String(e.activite || ""));
  if (!cle) throw new Error("Clé d'envoi absente (secret BREVO_API_KEY)");
  const num = String(e.destinataire).replace(/[^0-9+]/g, "").replace(/^0/, "+33");
  const d = delai();
  const rep = await fetch("https://api.brevo.com/v3/transactionalSMS/sms", {
    method: "POST",
    headers: { "api-key": cle, "Content-Type": "application/json", accept: "application/json" },
    signal: d.signal,
    body: JSON.stringify({
      sender: (r.sms_expediteur || "ONIQ").slice(0, 11),
      recipient: num,
      content: e.corps.slice(0, 640),
      type: "transactional",
    }),
  }).finally(d.fin);
  if (!rep.ok) throw new Error(`Brevo SMS ${rep.status} ${await rep.text()}`);
  await rep.text().catch(() => "");
}

// La même règle que ls_tel_norm() dans la base, mot pour mot : les
// chiffres seuls, et +33 devient 0. Si les deux divergeaient, un STOP
// reçu par SMS ne bloquerait plus le numéro écrit autrement.
function telNorm(t: unknown): string {
  const s = String(t ?? "").trim();
  return /^\+33/.test(s)
    ? "0" + s.replace(/^\+33\s*(\(0\))?/, "").replace(/[^0-9]/g, "")
    : s.replace(/[^0-9]/g, "");
}

// Réserver une ligne avant de l'envoyer. L'écriture est conditionnelle
// (statut encore en_attente) et rend la ligne modifiée : si deux
// moteurs se la disputent, un seul reçoit une ligne, l'autre rien.
async function reserver(id: string): Promise<boolean> {
  const r = await fetch(
    `${URL_BASE}/rest/v1/ls_envois?id=eq.${encodeURIComponent(id)}&statut=eq.en_attente`, {
    method: "PATCH",
    headers: { ...H, Prefer: "return=representation" },
    body: JSON.stringify({ statut: "en_cours", pris_le: new Date().toISOString() }),
  });
  if (!r.ok) throw new Error(`ls_envois ${r.status} ${await r.text()}`);
  const l = await r.json().catch(() => []);
  return Array.isArray(l) && l.length > 0;
}

async function expedier(r: Reglages) {
  const plafond = Number(r.plafond_jour ?? "200");
  const debutJour = new Date(); debutJour.setHours(0, 0, 0, 0);
  const dejaJ = await lire("ls_envois",
    `select=id&statut=eq.envoye&envoye_le=gte.${debutJour.toISOString()}&limit=1000`);
  let budget = Math.max(0, plafond - dejaJ.length);
  if (budget === 0) return { envoyes: 0, echecs: 0, note: "plafond du jour atteint" };

  // Une ligne réservée depuis plus d'un quart d'heure a été oubliée
  // par un moteur coupé en route : on la remet en file, sinon elle ne
  // partirait jamais et personne ne saurait pourquoi.
  const limite = new Date(Date.now() - 15 * 60e3).toISOString();
  await majr("ls_envois",
    `statut=eq.en_cours&or=(pris_le.is.null,pris_le.lt.${encodeURIComponent(limite)})`,
    { statut: "en_attente", pris_le: null }).catch(() => {});

  // Les prioritaires d'abord : ce sont ceux que quelqu'un attend.
  const file = await lire("ls_envois",
    `select=*&statut=eq.en_attente&a_envoyer_le=lte.${new Date().toISOString()}` +
    `&order=prioritaire.desc,a_envoyer_le.asc&limit=${Math.min(budget + 40, 80)}`);
  // La liste d'opposition se lit sur sa forme normalisée, calculée par
  // la base : un numéro écrit avec des espaces ou un +33 y est le même
  // qu'un numéro écrit d'un bloc.
  const stop = await lire("ls_desinscrits", "select=adresse_norm&limit=5000");
  const bloques = new Set(stop.map((s: any) => String(s.adresse_norm ?? "")).filter(Boolean));

  // Les campagnes ont leurs propres garde-fous : la fenêtre, le
  // plafond de chaque boîte, et le rythme par passage. Douze par heure
  // sur un moteur qui passe toutes les cinq minutes, c'est un message
  // par passage ; vingt, c'est un ou deux.
  const boites = await boitesDuJour();
  const cadences = new Map<string, number>();   // campagne -> messages encore permis ce passage
  const samedis = new Map<string, boolean>();  // campagne -> écrit-elle le samedi matin
  let derniereCampagne = 0;

  let envoyes = 0, echecs = 0;
  for (const e of file) {
    const id = encodeURIComponent(String(e.id));
    if (e.campagne_id) {
      const cid = String(e.campagne_id);
      if (!cadences.has(cid)) {
        let cadence = 12, sam = false;
        let c: any[] = [];
        try {
          c = await lire("ls_campagnes",
            `select=cadence_h,statut,samedi&id=eq.${encodeURIComponent(cid)}&limit=1`);
        } catch {
          // La colonne « samedi » n'existe pas encore : on relit sans
          // elle plutôt que de perdre le statut et la cadence.
          try {
            c = await lire("ls_campagnes",
              `select=cadence_h,statut&id=eq.${encodeURIComponent(cid)}&limit=1`);
          } catch { /* douze par défaut */ }
        }
        if (c[0]) {
          cadence = Math.min(20, Math.max(1, Number(c[0].cadence_h ?? 12)));
          sam = c[0].samedi === true;
          if (!["programmee", "en_cours"].includes(String(c[0].statut))) cadence = 0;
        }
        samedis.set(cid, sam);
        const parPassage = cadence / 12;
        cadences.set(cid, Math.floor(parPassage) + (Math.random() < parPassage % 1 ? 1 : 0));
      }
      // La fenêtre se juge campagne par campagne, puisque le samedi
      // aussi. Le reste de la file, lui, part quand il veut.
      if (!fenetreCampagne(new Date(), samedis.get(cid) === true)) continue;
      if ((cadences.get(cid) ?? 0) <= 0) continue;
      const b = e.boite_id ? boites.get(String(e.boite_id)) : undefined;
      if (!b || !b.actif) {
        await majr("ls_envois", `id=eq.${id}`, { erreur: "boîte d'envoi absente ou coupée" }).catch(() => {});
        continue;
      }
      if (b.jour >= b.plafond) continue;   // demain, à la prochaine fenêtre
      // Deux messages d'une même campagne dans un même passage ne se
      // suivent pas à la seconde : on souffle entre les deux.
      if (derniereCampagne) {
        const pause = 15000 + Math.floor(Math.random() * 25000);
        await new Promise((ok) => setTimeout(ok, pause));
      }
      cadences.set(cid, (cadences.get(cid) ?? 1) - 1);
      b.jour++;
      derniereCampagne = Date.now();
    }
    const dest = e.canal === "sms"
      ? telNorm(e.destinataire)
      : String(e.destinataire ?? "").toLowerCase().trim();
    if (!dest || bloques.has(dest)) {
      await majr("ls_envois", `id=eq.${id}`,
        { statut: "annule", erreur: "opposition ou adresse absente" });
      continue;
    }
    // Les heures d'envoi protègent les gens qu'on dérange, pas ceux
    // qui attendent une réponse. Un message déclenché par un commercial
    // part tout de suite ; un message de prospection attend 9 h.
    if (!e.prioritaire && !e.campagne_id && !heureOuvrable(r)) continue;
    if (!e.prioritaire && budget <= 0) continue;
    // Quelqu'un d'autre l'a prise entre-temps : on passe.
    if (!(await reserver(String(e.id)))) continue;
    let messageId = "";
    try {
      const rm = pourMaison(r, String(e.activite || ""));
      if (e.canal === "sms") await envoyerSms(rm, e);
      else if (e.canal === "push") await envoyerPush(e);
      else messageId = await envoyerEmail(rm, e);
    } catch (err) {
      // Trois essais, dix minutes d'écart. Si la base refuse même de
      // noter l'échec, la ligne reste en_cours et le quart d'heure
      // ci-dessus la reprendra : on ne perd rien, on ne double rien.
      const t = (e.tentatives ?? 0) + 1;
      await majr("ls_envois", `id=eq.${id}`, {
        statut: t >= 3 ? "echec" : "en_attente",
        tentatives: t,
        erreur: String(err).slice(0, 400),
        pris_le: null,
        a_envoyer_le: new Date(Date.now() + 10 * 60e3).toISOString(),
      }).catch(() => {});
      echecs++;
      continue;
    }
    // Le message est parti : le marquer est hors du try, sinon une
    // base qui tousse à cet instant remettrait en file un message déjà
    // reçu. On insiste une fois, et on compte l'envoi quoi qu'il arrive.
    const fait = { statut: "envoye", envoye_le: new Date().toISOString(),
                   tentatives: (e.tentatives ?? 0) + 1, pris_le: null,
                   ...(messageId ? { message_id: messageId } : {}) };
    await majr("ls_envois", `id=eq.${id}`, fait).catch(async () => {
      await new Promise((ok) => setTimeout(ok, 1500));
      await majr("ls_envois", `id=eq.${id}`, fait).catch(() => {});
    });
    envoyes++;
    if (!e.prioritaire) budget--;
  }
  return { envoyes, echecs, note: "" };
}

// ═══════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════
// LA MOISSON ET LE VERSEMENT
//
// Deux travaux que le navigateur faisait, et qu'il ne devrait jamais
// avoir faits : chercher les entreprises, et faire entrer les
// contacts en campagne. Tant que c'était le navigateur, il fallait
// qu'une fenêtre reste ouverte, et quelqu'un devant.
//
// Ici, c'est le moteur, toutes les cinq minutes, que quelqu'un
// regarde ou non. Il prend la tranche de moisson la plus ancienne,
// en fait un morceau, la repose, cherche quelques adresses, puis
// fait entrer en campagne ceux qui passent le filtre. Rien ne se
// perd si une invocation est coupée : tout est repris au tour
// suivant, exactement là où il s'était arrêté.
// ═══════════════════════════════════════════════════════════════════

const PROSPECTION = `${URL_BASE}/functions/v1/prospection`;

async function prospecter(corps: unknown): Promise<any> {
  const d = delai(50000);
  try {
    const r = await fetch(PROSPECTION, {
      method: "POST",
      headers: { apikey: CLE_SERVICE, Authorization: `Bearer ${CLE_SERVICE}`,
                 "Content-Type": "application/json" },
      body: JSON.stringify(corps), signal: d.signal,
    });
    const t = await r.text();
    if (!r.ok) throw new Error(t.slice(0, 200));
    return JSON.parse(t);
  } finally { d.fin(); }
}

// Le registre, tranche par tranche, puis les adresses. Le budget est
// serré : une invocation d'Edge Function ne dure pas éternellement, et
// l'envoi passe avant tout le reste.
async function moissonner(budgetMs: number): Promise<{ detail: string[] }> {
  const t0 = Date.now();
  const detail: string[] = [];
  let crees = 0, mails = 0, tranches = 0;

  // ── Le registre ──────────────────────────────────────────────────
  while (Date.now() - t0 < budgetMs * 0.55) {
    let l: any[] = [];
    try {
      l = await lire("ls_moisson",
        "select=*&fini=is.false&order=tourne_le.asc.nullsfirst&limit=1");
    } catch { break; }
    if (!l.length) break;
    const m = l[0];
    // Poser la date tout de suite : si l'invocation meurt en route, la
    // tranche suivante sera prise au tour d'après, pas celle-ci en
    // boucle.
    await majr("ls_moisson", `id=eq.${encodeURIComponent(String(m.id))}`,
      { tourne_le: new Date().toISOString() }).catch(() => {});
    try {
      const g = await prospecter({ action: "chercher", activite: m.activite, naf: m.naf,
        metier: m.metier, departement: m.departement, source: "registre",
        page: Number(m.page) || 1 });
      const n = Number(g.crees) || 0;
      crees += n; tranches++;
      const suivante = Number(g.page_suivante) || 0;
      await majr("ls_moisson", `id=eq.${encodeURIComponent(String(m.id))}`,
        { page: suivante || Number(m.page) || 1, fini: !suivante,
          fiches: (Number(m.fiches) || 0) + n, souci: "" });
    } catch (err) {
      const souci = String((err as Error).message ?? err).slice(0, 200);
      await majr("ls_moisson", `id=eq.${encodeURIComponent(String(m.id))}`, { souci }).catch(() => {});
      detail.push(`moisson ${m.naf}/${m.departement} : ${souci.slice(0, 80)}`);
      break;
    }
  }

  // ── Les adresses des fiches qui n'en ont pas ─────────────────────
  // Deux passes : on lit d'abord les sites déjà connus, puis on
  // retrouve les sites à partir des noms. C'est la partie lente, et
  // c'est elle qui fait la valeur du fichier.
  let maisons: string[] = [];
  try {
    const l = await lire("ls_campagnes",
      "select=activite&statut=in.(brouillon,programmee,en_cours)&limit=50");
    maisons = [...new Set(l.map((x: any) => String(x.activite)))].filter(Boolean);
  } catch { maisons = []; }
  for (const act of maisons) {
    for (const action of ["tel_depuis_site", "tel_par_domaine"]) {
      while (Date.now() - t0 < budgetMs) {
        try {
          const k = await prospecter({ action, activite: act, viser: "email", limite: 100 });
          mails += Number(k.mails) || 0;
          if (!Number(k.traites) || !Number(k.restants)) break;
        } catch (err) {
          detail.push(`adresses ${act} : ${String((err as Error).message ?? err).slice(0, 80)}`);
          break;
        }
      }
    }
  }
  if (tranches || crees || mails)
    detail.push(`moisson : ${tranches} tranche(s), ${crees} fiche(s), ${mails} adresse(s)`);
  return { detail };
}

// ── Le versement : qui entre en campagne, et quand ─────────────────
//
// L'audience d'une campagne est une requête, pas une liste figée. À
// chaque passage, on la rejoue, on retire ceux qui y sont déjà, ceux
// qui ont dit stop, ceux à qui on a écrit récemment, et les adresses
// de standard. Ce qui reste entre, dans la limite de ce que les
// boîtes peuvent encore envoyer aujourd'hui.

const GENERIQUES = new Set(["contact","info","infos","accueil","standard","bonjour","hello",
  "secretariat","administration","compta","comptabilite","rh","commercial","communication",
  "marketing","support","noreply","no-reply","nepasrepondre","ne-pas-repondre","postmaster",
  "webmaster","admin","office","courrier","mail","reception","sav","service","services",
  "facturation","recrutement","candidature"]);

function estGenerique(m: string): boolean {
  return GENERIQUES.has(String(m ?? "").toLowerCase().split("@")[0].trim());
}

function guillemets(l: unknown[]): string {
  return l.map((x) => `"${String(x).replace(/"/g, "")}"`).join(",");
}

async function verserCampagnes(pied: string): Promise<{ entres: number; detail: string[] }> {
  const detail: string[] = [];
  let entres = 0;
  let cs: any[] = [];
  try { cs = await lire("ls_campagnes", "select=*&statut=in.(programmee,en_cours)&limit=20"); }
  catch (err) { return { entres, detail: [`versement : ${String((err as Error).message ?? err).slice(0, 120)}`] }; }
  if (!cs.length) return { entres, detail };

  const boitesToutes = await boitesDuJour();
  // La liste d'opposition, lue une fois pour toutes les campagnes.
  const stop = new Set<string>();
  try {
    for (const x of await lire("ls_desinscrits", "select=adresse&canal=eq.email&limit=5000"))
      stop.add(String(x.adresse).toLowerCase().trim());
  } catch { /* sans liste, on continue : le moteur revérifie à l'envoi */ }

  for (const c of cs) {
    try {
      const cible = (c.cible ?? {}) as Record<string, any>;
      const qui = String(cible.qui ?? "partenaires");
      const surProspects = (qui === "prospects" || qui === "comptes");
      const table = surProspects ? "ls_prospects" : "ls_prescripteurs";

      // Ce que les boîtes de cette campagne peuvent encore avaler.
      const bs = (Array.isArray(c.boites) ? c.boites : [])
        .map((id: string) => boitesToutes.get(String(id)))
        .filter((b: any) => b && b.actif);
      if (!bs.length) continue;
      const place = bs.reduce((a: number, b: any) => a + Math.max(0, b.plafond - b.jour), 0);
      if (place <= 0) continue;

      // La même définition d'audience que dans le CRM, mot pour mot :
      // ce qui est annoncé à l'écran est exactement ce qui part.
      let q: string;
      if (surProspects) {
        q = "select=id,societe,dirigeant,email,ville,code_postal,activite,tel"
          + "&email=neq.&email=not.is.null&email_invalide=is.false"
          + `&activite=eq.${encodeURIComponent(String(c.activite))}`
          + "&etape=not.in.(Gagne,Perdu)"
          + (qui === "prospects" ? "&est_lead=is.true" : "&est_lead=is.false");
        if (cible.jamais_appeles) q += "&appel_resultat=is.null";
        if (cible.exclure_lies !== false) q += "&partenaire_id=is.null";
      } else {
        q = "select=id,nom,contact,email,ville,code_postal,activite,type,email_origine"
          + "&email=neq.&email=not.is.null&email_invalide=is.false"
          + `&activite=eq.${encodeURIComponent(String(c.activite))}`
          + "&statut=not.in.(Signé,Abandonné)";
        if (Array.isArray(cible.types) && cible.types.length)
          q += `&type=in.(${guillemets(cible.types)})`;
        if (cible.jamais_appeles) q += "&appel_resultat=is.null";
        if (cible.nominatif) q += "&email_origine=in.(direction,personne)";
        if (cible.exclure_lies !== false)
          q += "&compte_email=is.null&or=(contrat_statut.is.null,contrat_statut.eq.aucun)";
        // D'où vient la fiche. « Pharow » veut dire : c'est lui qui a
        // fourni l'adresse. Deux campagnes identiques, l'une sur le
        // fichier acheté et l'autre sur la moisson gratuite, et on
        // saura en quinze jours lequel des deux rapporte.
        if (cible.source === "pharow") q += "&source=eq.Pharow";
        else if (cible.source === "gratuit") q += "&or=(source.is.null,source.neq.Pharow)";
      }
      const deps = String(cible.departements ?? "").split(/[\s,;]+/).filter(Boolean);
      if (deps.length === 1) q += `&code_postal=like.${deps[0].padStart(2, "0")}*`;
      else if (deps.length > 1)
        q += `&or=(${deps.map((d) => `code_postal.like.${d.padStart(2, "0")}*`).join(",")})`;
      q += `&order=${surProspects ? "created_at" : "cree_le"}.desc&limit=1200`;

      let fiches: any[] = [];
      try { fiches = await lire(table, q); }
      catch (err) { detail.push(`audience ${c.nom} : ${String((err as Error).message ?? err).slice(0, 100)}`); continue; }
      if (!fiches.length) continue;
      // L'ordre d'entrée compte : on ne verse qu'un lot par passage,
      // dans la limite de ce que les boîtes peuvent envoyer. Ce qui
      // part en premier doit donc être ce qu'on a de meilleur. Une
      // adresse payée et nominative passe devant une adresse devinée
      // sur un site.
      fiches.sort((a, b) => {
        const p = (x: any) => (String(x.source ?? "") === "Pharow" ? 2 : 0)
          + (["direction", "personne"].includes(String(x.email_origine ?? "")) ? 1 : 0);
        return p(b) - p(a);
      });

      // Déjà dans cette campagne ?
      const deja = new Set<string>();
      try {
        for (const s of await lire("ls_sequences",
          `select=email&campagne_id=eq.${encodeURIComponent(String(c.id))}&limit=5000`))
          deja.add(String(s.email).toLowerCase().trim());
      } catch { /* mieux vaut réessayer d'insérer : la base refuse les doublons */ }

      // Écrit récemment, toutes campagnes confondues.
      const recents = new Set<string>();
      const jours = cible.exclure_jours != null ? Number(cible.exclure_jours) : 90;
      if (jours > 0) {
        const dep = new Date(Date.now() - jours * 864e5).toISOString();
        try {
          for (const s of await lire("ls_sequences", `select=email&cree_le=gte.${dep}&limit=5000`))
            recents.add(String(s.email).toLowerCase().trim());
        } catch { /* pas bloquant */ }
      }

      const sansGeneriques = cible.exclure_generiques !== false;
      const vus = new Set<string>();
      const neufs: any[] = [];
      for (const x of fiches) {
        if (neufs.length >= Math.min(place, 150)) break;
        const m = String(x.email ?? "").toLowerCase().trim();
        if (!m || !/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(m)) continue;
        if (vus.has(m) || deja.has(m) || stop.has(m) || recents.has(m)) continue;
        // Une adresse de standard, contact@ ou info@, n'a rien
        // d'inutilisable : ce qui est inutilisable, c'est d'écrire à
        // « Bonjour » sans savoir à qui. Le registre public donne le
        // nom du dirigeant gratuitement, et une secrétaire fait suivre
        // un message adressé à quelqu'un. On garde donc les génériques
        // dont on connaît le destinataire, et on écarte les autres.
        const aQui = String(x.dirigeant ?? String(x.contact ?? "").split(" — ")[0] ?? "").trim();
        if (sansGeneriques && estGenerique(m) && !(cible.generiques_nominatifs === true && aQui)) continue;
        vus.add(m); neufs.push(x);
      }
      if (!neufs.length) continue;

      // Les boîtes, à tour de rôle, chacune dans ce qui lui reste.
      const restes = bs.map((b: any) => ({ b, reste: Math.max(0, b.plafond - b.jour) }));
      let tour = 0;
      function prochaine() {
        for (let k = 0; k < restes.length; k++) {
          const r = restes[(tour + k) % restes.length];
          if (r.reste > 0) { r.reste--; tour = (tour + k + 1) % restes.length; return r.b; }
        }
        return null;
      }

      const signature = String(c.signature ?? "").trim();
      const hab = String(c.habillage ?? "maison");
      for (const x of neufs) {
        const b = prochaine();
        if (!b) break;
        const email = String(x.email).toLowerCase().trim();
        try {
          const societe = String(x.societe ?? x.nom ?? "");
          const dirigeant = String(x.dirigeant ?? String(x.contact ?? "").split(" — ")[0] ?? "");
          const r = await ecrire("ls_sequences", {
            campagne_id: c.id, email,
            partenaire_id: surProspects ? null : x.id,
            prospect_id: surProspects ? x.id : null,
            boite_id: b.id,
            societe, dirigeant, ville: x.ville ?? "", activite: c.activite,
          }, "return=representation");
          const s = Array.isArray(r) ? r[0] : null;
          if (!s) continue;   // déjà en séquence : rien à faire
          const d = { societe, dirigeant, ville: x.ville ?? "",
                      activite: c.activite, expediteur: b.nom_expediteur ?? "" };
          const rempli = enTeteAttention(email, dirigeant) + remplir(String(c.corps ?? ""), d);
          const texte = rempli.trim() + (signature ? "\n\n" + signature : "");
          await ecrire("ls_envois", {
            cle: `seq:${s.id}:1`,
            canal: "email",
            destinataire: email,
            objet: remplir(String(c.objet ?? ""), d),
            corps: hab === "sobre" ? texte : rempli.trim(),
            corps_html: mailCampagne(rempli, signatureLue(signature), String(c.activite), hab, String(pied ?? "")),
            prospect_id: surProspects ? x.id : null,
            partenaire_id: surProspects ? null : x.id,
            societe, activite: String(c.activite),
            expediteur_nom: b.nom_expediteur || "",
            expediteur_email: b.adresse_envoi || b.adresse,
            repondre_a: b.adresse,
            owner_email: String(c.owner_email ?? ""),
            statut: "en_attente", prioritaire: false,
            campagne_id: c.id, boite_id: b.id, sequence_id: s.id, etape_seq: 1,
            // Étalé dans l'heure : le moteur pose ses propres pauses,
            // mais deux contacts nés à la même seconde ne doivent pas
            // partir à la même seconde.
            a_envoyer_le: new Date(Date.now() + Math.floor(Math.random() * 3600e3)).toISOString(),
          }, "return=minimal");
          entres++;
        } catch (err) {
          detail.push(`versement ${email} : ${String((err as Error).message ?? err).slice(0, 90)}`);
        }
      }
      // Une campagne qui a versé son premier contact n'est plus
      // seulement programmée : elle tourne.
      if (entres && String(c.statut) === "programmee")
        await majr("ls_campagnes", `id=eq.${encodeURIComponent(String(c.id))}`,
          { statut: "en_cours", maj_le: new Date().toISOString() }).catch(() => {});
    } catch (err) {
      detail.push(`campagne ${c.nom} : ${String((err as Error).message ?? err).slice(0, 100)}`);
    }
  }
  if (entres) detail.push(`entrés en campagne : ${entres}`);
  return { entres, detail };
}

Deno.serve(async (req) => {
  if (!(await appelantAutorise(req))) {
    return new Response(JSON.stringify({ ok: false, erreur: "Accès refusé." }), {
      status: 403, headers: { "Content-Type": "application/json" },
    });
  }
  try {
    const r = await reglages();
    // Fabriquer peut échouer en entier (les règles illisibles, par
    // exemple) : ce qui attend déjà dans la file doit partir quand même.
    let f = { posees: 0, detail: [] as string[] };
    try { f = await fabriquer(r); }
    catch (err) { f.detail.push(`fabriquer : ERREUR ${String((err as Error).message ?? err).slice(0, 200)}`); }
    // Les mails 2 et 3 des campagnes, quand leur jour est venu.
    try { const s2 = await poserSuites(String(r.pied_email ?? "")); f.posees += s2.posees; f.detail.push(...s2.detail); }
    catch (err) { f.detail.push(`séquences : ERREUR ${String((err as Error).message ?? err).slice(0, 200)}`); }
    // Les contacts qui viennent d'entrer dans le fichier, versés dans
    // les campagnes qui les cherchent. Avant l'expédition : ce qui
    // entre maintenant peut partir dans la foulée.
    let vers = { entres: 0, detail: [] as string[] };
    try { vers = await verserCampagnes(String(r.pied_email ?? "")); f.detail.push(...vers.detail); }
    catch (err) { f.detail.push(`versement : ERREUR ${String((err as Error).message ?? err).slice(0, 200)}`); }
    const x = await expedier(r);
    // Le journal s'écrit ici, avant la moisson : si l'invocation est
    // coupée pendant qu'on ramasse, on saura quand même ce qui est
    // parti. La moisson, elle, reprend d'elle-même au tour suivant.
    await ecrire("ls_moteur", {
      fabriques: f.posees, envoyes: x.envoyes, echecs: x.echecs,
      detail: [f.detail.join(" · "), x.note].filter(Boolean).join(" — "),
    });
    // La moisson passe en dernier : elle prend ce qui reste de temps,
    // et jamais celui de l'envoi.
    const mo: string[] = [];
    try { const ms = await moissonner(60000); mo.push(...ms.detail); }
    catch (err) { mo.push(`moisson : ERREUR ${String((err as Error).message ?? err).slice(0, 200)}`); }
    if (mo.length) {
      f.detail.push(...mo);
      await ecrire("ls_moteur", { fabriques: 0, envoyes: 0, echecs: 0, detail: mo.join(" · ") })
        .catch(() => {});
    }
    return new Response(JSON.stringify({ ok: true, ...f, ...x, entres: vers.entres }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    await ecrire("ls_moteur", { fabriques: 0, envoyes: 0, echecs: 0, detail: String(e).slice(0, 400) })
      .catch(() => {});
    return new Response(JSON.stringify({ ok: false, erreur: String(e) }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
});
