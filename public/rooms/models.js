// Decision Rooms thinking models (docs/decision-models.md). The core five at launch, plus RAPID as an add-on.
// Shared by the browser (the model chooser and the demo) and the server (lib/rooms.js), like math.js.

export const MODELS = {
  wrap: {
    framework: "WRAP", by: "Chip and Dan Heath",
    line: { en: "A careful call for decisions that are hard to undo", ar: "قرار متأنٍّ للقرارات التي يصعب التراجع عنها" }
  },
  quick: {
    framework: "Type 1 / Type 2", by: "Amazon",
    line: { en: "A fast call for decisions you can undo", ar: "قرار سريع للقرارات التي يمكن التراجع عنها" }
  },
  cynefin: {
    framework: "Cynefin", by: "Dave Snowden",
    line: { en: "Make sense of a messy situation before choosing", ar: "افهم الموقف المعقّد قبل أن تختار" }
  },
  mece: {
    framework: "MECE", by: "Barbara Minto, McKinsey",
    line: { en: "Break a big question into clear parts and answer each", ar: "قسّم السؤال الكبير إلى أجزاء واضحة وأجب عن كل جزء" }
  },
  standard: {
    framework: "Balanced analysis", by: "Decision Rooms",
    line: { en: "Scores, likely outcomes and a pre-mortem, for most decisions", ar: "تقييم ونتائج محتملة وتحليل استباقي للفشل، لمعظم القرارات" }
  }
};
export const MODEL_IDS = Object.keys(MODELS);

export const RAPID = {
  framework: "RAPID", by: "Bain & Company",
  line: { en: "Name who recommends, who must agree, and who carries it out", ar: "حدّد من يوصي، ومن يجب أن يوافق، ومن ينفّذ" }
};

// The triage model call only reads signals from the question; these rules turn them into a
// recommendation, so every recommendation is explainable and the same input always gets the same answer.
// signals: {door: "one-way"|"two-way", stakes: "low"|"medium"|"high", clarity: "clear"|"unclear",
//           breadth: "focused"|"broad", approvals: boolean}
export function recommend(s = {}) {
  const fits = [];
  if (s.clarity === "unclear") fits.push("cynefin");
  if (s.breadth === "broad") fits.push("mece");
  if (s.door === "one-way" && s.stakes !== "low") fits.push("wrap");
  if (s.door === "two-way" && s.stakes !== "high") fits.push("quick");
  fits.push("standard");
  const order = [...new Set([...fits, "wrap", "standard", "mece", "cynefin", "quick"])];
  return { model: order[0], why: "why_" + order[0], alternatives: order.slice(1, 3), rapid: s.approvals === true };
}

// A rough guess with no AI call (demo mode, or when triage is unavailable).
export function guessSignals({ question = "", options = [], context = "" }) {
  const text = (question + " " + context).toLowerCase();
  return {
    door: /\b(acquire|acquisition|merge|sell|exit|hire|fire|resign|build|invest|loan|equity|close|launch)\b|استحواذ|بيع|توظيف|استثمار|قرض/.test(text) ? "one-way" : "two-way",
    stakes: /\b(million|billion|board|law|regulation|merger|company|government)\b|مليون|مليار|قانون|حكومة/.test(text) ? "high" : "medium",
    clarity: options.filter(o => String(o).trim()).length < 2 ? "unclear" : "clear",
    breadth: /\b(market|expand|strategy|country|region|economy)\b|سوق|توسّع|استراتيجية|اقتصاد/.test(text) ? "broad" : "focused",
    approvals: /\b(board|legal|regulator|approval|committee|member states|council)\b|مجلس|موافقة|لجنة|قانوني/.test(text)
  };
}
