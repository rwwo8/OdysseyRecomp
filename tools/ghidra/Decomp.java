// Odyssey Recomp: decompile a few functions of the raw main image (no auto-analysis).
// Args: <symbols file> <output file> <hex address>...  (first run also labels every symbol: once per project)
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.SourceType;
import java.io.BufferedReader;
import java.io.FileReader;
import java.io.PrintWriter;

public class Decomp extends GhidraScript {
    @Override
    protected void run() throws Exception {
        String[] a = getScriptArgs();
        String syms = a[0], out = a[1];
        if (currentProgram.getSymbolTable().getNumSymbols() < 1000) {
            try (BufferedReader r = new BufferedReader(new FileReader(syms))) {
                String line;
                while ((line = r.readLine()) != null) {
                    int sp = line.indexOf(' ');
                    if (sp < 0) continue;
                    Address ad = toAddr(Long.parseUnsignedLong(line.substring(0, sp), 16));
                    try { createLabel(ad, line.substring(sp + 1), true, SourceType.IMPORTED); } catch (Exception e) { }
                }
            }
        }
        DecompInterface d = new DecompInterface();
        d.openProgram(currentProgram);
        try (PrintWriter w = new PrintWriter(out)) {
            for (int i = 2; i < a.length; i++) {
                Address ad = toAddr(Long.parseUnsignedLong(a[i], 16));
                disassemble(ad);
                Function f = getFunctionAt(ad);
                if (f == null) f = createFunction(ad, null);
                if (f == null) { w.println("// " + a[i] + ": no function"); continue; }
                // the callees too, so calls show their names and signatures
                for (Function c : f.getCalledFunctions(monitor)) { }
                DecompileResults res = d.decompileFunction(f, 120, monitor);
                w.println("// ==== " + a[i] + " " + f.getName());
                w.println(res.getDecompiledFunction() != null ? res.getDecompiledFunction().getC() : "// failed: " + res.getErrorMessage());
            }
        }
    }
}
