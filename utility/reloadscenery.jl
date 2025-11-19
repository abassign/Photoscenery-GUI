using Sockets

function debug_fgfs_raw(; host="127.0.0.1", port=5000)
    println("\n=== DIAGNOSTICA CONNESSIONE FLIGHTGEAR ===")

    try
        sock = connect(host, port)
        println("✔ Connesso al socket.")

        # 1. Leggiamo il messaggio di benvenuto (se c'è)
        sleep(0.5)
        if bytesavailable(sock) > 0
            welcome = String(readavailable(sock))
            println("\n[SERVER MESSAGE]:\n$welcome")
        else
            println("\n[SERVER MESSAGE]: (Nessun messaggio iniziale)")
        end

        # 2. Inviamo un comando semplice
        cmd = "get /position/latitude-deg"
        println("\n--> Invio comando: '$cmd'")
        write(sock, "$cmd\r\n")

        # 3. Aspettiamo e leggiamo TUTTO quello che torna
        sleep(1.0) # Attesa lunga per essere sicuri di prendere tutto

        if bytesavailable(sock) > 0
            raw_bytes = readavailable(sock)
            raw_str = String(raw_bytes)

            println("\n<-- RISPOSTA GREZZA (Tra i simboli |):")
            println("|" * raw_str * "|")

            println("\n--- Analisi Risposta ---")
            println("Lunghezza stringa: $(length(raw_str)) caratteri")
            m = match(r"[-+]?\d+\.\d+", raw_str)
            if m !== nothing
                println("Numero trovato: $(m.match)")
            else
                println("NESSUN NUMERO TROVATO nella risposta.")
            end
        else
            println("\n<-- NESSUNA RISPOSTA RICEVUTA (Buffer vuoto)")
        end

        close(sock)
        println("\n=== FINE TEST ===")

        catch e
        println("ERRORE DI CONNESSIONE: $e")
        println("Verifica che FGFS sia avviato con: --telnet=$port")
    end
end

debug_fgfs_raw()
