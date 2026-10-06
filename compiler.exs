if System.version() != "1.20.3" or System.otp_release() != "28", do: raise("Runtime inattendu")
target = :code.lib_dir(:tymeslot, :ebin) |> List.to_string()
if not String.contains?(target, "tymeslot-1.15.7/"), do: raise("Release inattendue")
Code.compiler_options(ignore_module_conflict: true)
files = Path.wildcard("/opt/hq-sources/*.ex")
# Le Mailer porte les fonctions ajoutées ; aucun nouveau module au boot.
files = Enum.sort_by(files, fn p -> if Path.basename(p) == "mailer.ex", do: 0, else: 1 end)
manifest = for file <- files, {module, beam} <- Code.compile_file(file) do
  path = Path.join(target, Atom.to_string(module) <> ".beam")
  File.write!(path, beam)
  %{module: Atom.to_string(module), sha256: Base.encode16(:crypto.hash(:sha256, beam), case: :lower)}
end
File.write!("/opt/hq-beam-manifest.json", Jason.encode!(manifest))
IO.puts("Modules HQ compilés : #{length(manifest)}")
