import java.util.*;

public class StudentGradeTracker {
    public static void main(String[] args) {
        Scanner sc = new Scanner(System.in);

        ArrayList<Integer> marks = new ArrayList<>();

        System.out.print("Enter number of students: ");
        int n = sc.nextInt();

        // Input with validation
        for (int i = 0; i < n; i++) {
            int mark;

            while (true) {
                System.out.print("Enter marks for student " + (i + 1) + ": ");
                mark = sc.nextInt();

                if (mark >= 0 && mark <= 100) {
                    break;
                } else {
                    System.out.println("Invalid input! Enter marks between 0 and 100.");
                }
            }

            marks.add(mark);
        }

        int sum = 0;
        int max = marks.get(0);
        int min = marks.get(0);

        // Calculations
        for (int m : marks) {
            sum += m;

            if (m > max) {
                max = m;
            }

            if (m < min) {
                min = m;
            }
        }

        double avg = (double) sum / n;

        // Display Report
        System.out.println("\n===== Student Report =====");
        System.out.println("Marks: " + marks);
        System.out.println("Average: " + avg);
        System.out.println("Highest: " + max);
        System.out.println("Lowest: " + min);

        // Grade System
        System.out.println("\nGrades:");
        for (int i = 0; i < n; i++) {
            int m = marks.get(i);
            char grade;

            if (m >= 90) grade = 'A';
            else if (m >= 75) grade = 'B';
            else if (m >= 50) grade = 'C';
            else grade = 'F';

            System.out.println("Student " + (i + 1) + ": " + grade);
        }

        sc.close();
    }
}