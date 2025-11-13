module AppLogger

using Dates, Logging, LoggingExtras

export init_logger

"""
init_logger(path; logger_mode::Int=1, min_level::LogLevel=Logging.Info)

Imposta il logger:
- logger_mode=0: SOLO file (nessuna console)
- logger_mode=1: file + console
"""
function init_logger(path::AbstractString;
                     logger_mode::Int = 1,
                     min_level::LogLevel = Logging.Info)

    # 1) Truncate the log file on startup
    open(path, "w") do io end

    # 2) Formatter for the FILE (now handles exceptions and flushing)
    function fmt_file(io, log)
        ts = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
        lvl = log.level
        msg = log.message

        # Print the standard log line
        println(io, "$ts $(rpad(lvl, 5)) $msg")

        # Check if the log call includes an exception and print it
        if haskey(log.kwargs, :exception)
            exc, bt = log.kwargs[:exception]
            println(io, "  └─ Exception Details:")
            exc_str = sprint(showerror, exc, bt)
            for line in split(exc_str, '\n')
                println(io, "    $line")
            end
        end

        # --- MODIFICA CHIAVE ---
        # Flush the stream immediately after writing to ensure the log is saved to disk.
        flush(io)
    end

    # 3) Formatter for the CONSOLE (simple message only)
    function fmt_console(io, log)
        println(stdout, log.message)
        if haskey(log.kwargs, :exception)
            exc, bt = log.kwargs[:exception]
            println(stdout, "  └─ Exception: ", sprint(showerror, exc))
        end
    end

    # 4) Logger for the file (always active)
    file_io = open(path, "a")
    # Ensure the file stream is closed correctly on program exit
    atexit(() -> close(file_io))

    file_logger = FormatLogger(fmt_file, file_io)
    file_logger_filtered = MinLevelLogger(file_logger, min_level)

    # 5) Mode handling
    if logger_mode == 0
        global_logger(file_logger_filtered)
    else
        console_logger = FormatLogger(fmt_console, stdout)
        console_logger_filtered = MinLevelLogger(console_logger, min_level)
        tee = TeeLogger(file_logger_filtered, console_logger_filtered)
        global_logger(tee)
    end

    # --- MODIFICA CHIAVE ---
    # Questa riga causava l'errore ed è stata rimossa.
    # Il flush viene ora gestito da fmt_file.
    # Base.invokelatest(Logging.global_logger).loggers[1].logger.stream.flushed = true
end

end
