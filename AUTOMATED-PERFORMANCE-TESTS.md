# Automated Testing

This document is meant to serve as a plan and guide on how to develop and integrate an automated performance testing suite into our CI/CD workflow. The workflow should be as follows:

## General workflow

1. A new PR is opened in ProcessMaker/processmaker and has the ci tag `ci:performance-tests` in the comment body. This triggers the automated-performance-tests job in the github actions workflow, similiar to how the `ci:deploy` tag automates the deployment of the instance.
2. When the new performanceTests github action job is triggered, it deploys a new nodegroup to the EKS cluster. This nodegroup runs a single r6a.xlarge ec2 instance dedicated for this PR. It creates a unique taint, key=performance,value=ci-# instance.
3. Once the node is up, the next step is to sequentially helm install the application and run performance tests. First with the current appVersion: develop. Once it has completed it's tests and recorded them, it does a helm uninstall of that develop deployment and installs the new appVersion build from the PR. It then runs those same tests against this version and records the results.
4. After the baseline and new pr performance tests have completed, the new dedicated node group is terminated and deleted.

### dedicated performance node groups per PR

To get an exact 1 to 1 performance comparison, we need to ensure the backend hardware is not contaminated from other deployments. to accomplish this the workflow will need to create a dedicated node group with a single r6a.xlarge ec2 instance. It needs to have a unique taint, key=performance,value=ci=### instance.

To make sure we aren't incurring lots of costs, we will need to delete the node group once all the tests have been completed and results reported.

the `ci:deploy` workflow currently deploys with the URL: *.engk8s.processmaker.net, for example: ci-b84ab3f9e1.engk8s.processmaker.net. the URL for the performance tags should follow the same format and just append -perf-baseline and -perf-update after the ci-# part of the subdomain, for example: ci-b84ab3f9e1-perf-baseline.engk8s.processmaker.net and ci-b84ab3f9e1-perf-update.engk8s.processmaker.net

### The tests

***results*** 
The tests will be k6 tests that are located in a separate private repository: https://github.com/ProcessMaker/automated-performance-metrics

The results should be reported in two locations:
- commented back into the original PR as a table the author can read
- into our grafana instance

***test selection***
right now we do not have a lot of tests, but as we build this out we expect the collection to expand. It will get to a point where running all the tests will take too long. So the idea will be to group the tests into categories that can be specified in ci tags. For example, if a developer is working on a branch that is meant to optimize database queries, they would want to only run the database tests. They would accomplish this by setting a ci tag: `ci:performance-tests-database`.
We should also just have an all encompassing ci tag `ci:performance-tests` that will run all tests.

### development milestones

1. get the new performance cicd framework working. when the tag is present in the pr, create the node group and install develop baseline instance using appVersion: develop. once installed do a quick curl check to /login to ensure 200. Then wipe and do the same with the new appVersion that was built. Do a quick /login curl to ensure it loads 200. then  helm uninstall, terminate dedicated ec2 instance and delete node group.
2. implement first users-index.js k6s test. Get the test reporting as a table in a comment in the PR. This report should show 3 things: performance results of baseline, performance results of update, and the +/-% in performance between the two.
3. get reports loading into our grafana instance.
4. add more tests and implement test categories. Allow for ci tags to be specified so that a group of tests can be run via category.