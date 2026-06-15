rootProject.name = "aws-ruby-database-driver-wrapper"

include("integration-testing")

project(":integration-testing").projectDir = file("spec/integration/host")
