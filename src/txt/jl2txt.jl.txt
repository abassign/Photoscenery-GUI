using FileWatching

"""
watch_and_clone_events(dir::String = pwd())

Monitora una directory usando il sistema di notifica del sistema operativo.
Reagisce istantaneamente alla creazione, modifica o eliminazione di file .jl.
Questa versione è compatibile con un'ampia gamma di versioni di Julia.
"""
function watch_and_clone_events(dir::String = pwd())
    println("▶️  Avvio monitoraggio event-driven di: $dir")
    println("    Reazione istantanea ai cambiamenti. Premi Ctrl+C per terminare.")

    # --- Funzioni Ausiliarie (invariate) ---
    function handle_change(path::String)
        if isfile(path) && endswith(path, ".jl")
            dest_path = path * ".txt"
            try
                cp(path, dest_path, force=true)
                println("✅ [CLONATO] Creato/aggiornato clone: $(basename(dest_path))")
                catch e
                println("⚠️  Errore durante la copia di $path: $e")
            end
        end
    end

    function handle_delete(path::String)
        if endswith(path, ".jl")
            clone_path = path * ".txt"
            try
                if isfile(clone_path)
                    rm(clone_path)
                    println("❌ [RIMOSSO] Eliminato clone: $(basename(clone_path))")
                end
                catch e
                println("⚠️  Errore durante la rimozione di $clone_path: $e")
            end
        end
    end

    # --- Fase Iniziale (invariata) ---
    println("🔎 Scansiono la directory per i file .jl esistenti...")
    try
        initial_files = filter(f -> endswith(f, ".jl"), readdir(dir))
        for filename in initial_files
            handle_change(joinpath(dir, filename))
        end
        println("✨ Scansione iniziale completata. Inizio monitoraggio.")
        catch e
        println("🛑 Errore durante la scansione iniziale: $e")
        return
    end

    # --- Avvio del Watcher (SEZIONE CORRETTA) ---
    try
        # Invece di un blocco "do", usiamo un loop "while" esplicito.
        while true
            # La funzione watch_folder(dir) si mette in pausa finché non
            # rileva un cambiamento, poi restituisce un oggetto 'event'.
            event = watch_folder(dir)

            # L'oggetto 'event' contiene le informazioni sul cambiamento.
            # I campi principali sono .path, .changed, e .renamed
            if event.changed
                # Un file esistente è stato modificato
                handle_change(event.path)
                elseif event.renamed
                # Questo evento può significare: creazione, cancellazione o rinomina.
                # Per capire cosa è successo, controlliamo se il file esiste.
                if isfile(event.path)
                    # Se esiste, è stato creato o rinominato.
                    handle_change(event.path)
                else
                    # Se non esiste più, è stato cancellato.
                    handle_delete(event.path)
                end
            end
        end
        catch e
        if e isa InterruptException
            println("\n🛑 Monitoraggio interrotto dall'utente.")
        else
            # Stampa l'errore per diagnostica
            println("\n🛑 Si è verificato un errore critico:")
            showerror(stdout, e)
            println()
        end
    finally
        println("👋 Applicazione terminata.")
    end
end

# --- Per avviare lo script ---
# include("watcher_events.jl")
# watch_and_clone_events()
