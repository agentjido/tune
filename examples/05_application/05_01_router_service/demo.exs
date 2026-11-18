%{before: before, after_install: after_install} = Tune.Examples.RouterService.run()
IO.puts("Risk 0.7 went to #{before} before install and #{after_install} after install.")
