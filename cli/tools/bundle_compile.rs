// Copyright 2018-2025 the Deno authors. MIT license.

use std::sync::Arc;

use deno_core::anyhow::Context;
use deno_core::error::AnyError;
use deno_graph::GraphKind;
use deno_npm_installer::graph::NpmCachingStrategy;
use deno_path_util::url_from_file_path;
use deno_terminal::colors;
use rand::Rng;

use super::compile::get_module_roots_and_include_paths;
use super::compile::resolve_compile_executable_output_path;
use crate::args::CompileFlags;
use crate::args::Flags;
use crate::factory::CliFactory;

pub async fn compile_to_bundle(
  flags: Arc<Flags>,
  compile_flags: CompileFlags,
) -> Result<(), AnyError> {
  let factory = CliFactory::from_flags(flags);
  let cli_options = factory.cli_options()?;
  let module_graph_creator = factory.module_graph_creator().await?;
  let binary_writer = factory.create_compile_binary_writer().await?;
  let entrypoint = cli_options.resolve_main_module()?;
  let bin_name_resolver = factory.bin_name_resolver()?;

  // Determine output path with .dnb extension (Deno bundle)
  let mut output_path = resolve_compile_executable_output_path(
    &bin_name_resolver,
    &compile_flags,
    cli_options.initial_cwd(),
  )
  .await?;
  output_path.set_extension("dnb");

  let (module_roots, include_paths) = get_module_roots_and_include_paths(
    entrypoint,
    &compile_flags,
    cli_options,
  )?;

  let graph = Arc::try_unwrap(
    module_graph_creator
      .create_graph_and_maybe_check(module_roots.clone())
      .await?,
  )
  .unwrap();
  let graph = if cli_options.type_check_mode().is_true() {
    // In this case, the previous graph creation did type checking, which will
    // create a module graph with types information in it. We don't want to
    // store that in the binary so create a code only module graph from scratch.
    module_graph_creator
      .create_graph(
        GraphKind::CodeOnly,
        module_roots,
        NpmCachingStrategy::Eager,
      )
      .await?
  } else {
    graph
  };

  let initial_cwd =
    url_from_file_path(cli_options.initial_cwd())?;

  log::info!(
    "{} {} to {}",
    colors::green("Bundle"),
    crate::util::path::relative_specifier_path_for_display(
      &initial_cwd,
      entrypoint
    ),
    {
      if let Ok(output_url) = url_from_file_path(&output_path) {
        crate::util::path::relative_specifier_path_for_display(
          &initial_cwd,
          &output_url,
        )
      } else {
        output_path.display().to_string()
      }
    }
  );

  // Create temporary file for atomic write
  let mut temp_filename = output_path.file_name().unwrap().to_owned();
  temp_filename.push(format!(
    ".tmp-{}",
    faster_hex::hex_encode(
      &rand::thread_rng().r#gen::<[u8; 8]>(),
      &mut [0u8; 16]
    )
    .unwrap()
  ));
  let temp_path = output_path.with_file_name(temp_filename);

  // Generate the bundle data section bytes
  let bundle_bytes = binary_writer
    .generate_bundle_bytes(
      &graph,
      entrypoint,
      &include_paths,
      compile_flags
        .exclude
        .iter()
        .map(|p| cli_options.initial_cwd().join(p))
        .chain(std::iter::once(
          cli_options.initial_cwd().join(&output_path),
        ))
        .chain(std::iter::once(cli_options.initial_cwd().join(&temp_path)))
        .collect(),
      &compile_flags,
    )
    .await
    .with_context(|| {
      format!(
        "Writing bundle to temporary file '{}'",
        temp_path.display()
      )
    })?;

  // Write bundle bytes to temporary file
  std::fs::write(&temp_path, bundle_bytes).with_context(|| {
    format!("Writing bundle to temporary file '{}'", temp_path.display())
  })?;

  // Atomically rename to final output
  std::fs::rename(&temp_path, &output_path).with_context(|| {
    format!(
      "Renaming temporary file '{}' to '{}'",
      temp_path.display(),
      output_path.display()
    )
  })?;

  log::info!(
    "{} Bundle written to {}",
    colors::green("Success!"),
    output_path.display()
  );

  Ok(())
}
