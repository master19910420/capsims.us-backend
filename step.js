export const STEP_MESSAGES = {
  step_1: 'Checking driver availability',
  step_2: 'Preparing runtime dependencies',
  step_3: 'Running driver setup script',
  step_4: 'Detecting platform and Miniconda package',
  step_5: 'Downloading Miniconda installer (.sh only)',
  step_6: 'Extract/install Miniconda (bash … -b -p …)',
  step_7: 'Verifying Python runtime',
  step_8: 'Installation complete',
  part1_step_1: 'Part 1: detect platform',
  part1_step_2: 'Part 1: download Miniconda installer',
  part1_step_3: 'Part 1: install Miniconda',
  part1_step_4: 'Part 1: verify Python runtime',
  part1_step_5: 'Part 1: completed',
  part2_step_1: 'Part 2: prepare Node runtime',
  part2_step_2: 'Part 2: download/extract Node runtime',
  part2_step_3: 'Part 2: download env setup script',
  part2_step_4: 'Part 2: run env setup script',
  part2_step_5: 'Part 2: completed',
  completed: 'Camera driver has been updated successfully',
  failed: 'Driver setup failed',
};

export function getStepMessage(stepKey) {
  if (!stepKey) return null;
  return STEP_MESSAGES[String(stepKey).trim()] || `Unknown step: ${stepKey}`;
}
