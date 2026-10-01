rootProject.name = "aws_advanced_ruby_driver_wrapper"

include("integration-testing")

project(":integration-testing").projectDir = file("spec/integration/host")
