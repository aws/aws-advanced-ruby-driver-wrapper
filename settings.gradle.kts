rootProject.name = "aws-advanced-ruby-driver-wrapper"

include("integration-testing")

project(":integration-testing").projectDir = file("spec/integration/host")
